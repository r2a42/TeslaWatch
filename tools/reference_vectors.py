#!/usr/bin/env python3
"""Reference implementation of the VCSEC-over-BLE client path, used to produce the golden
vectors that TeslaKitTests asserts against. Uses protobuf bindings generated from Tesla's .proto
files, so it cross-checks the hand-written Swift wire encoder independently.

Run:  python3 -I tools/reference_vectors.py   (after generating tools/pygen, see README)
"""
import hashlib
import hmac
import struct
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0] + "/pygen")

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

import signatures_pb2 as sig
import universal_message_pb2 as um
import vcsec_pb2 as vc
import keys_pb2 as keys

# Test keys published in protocol.md. Never enroll these on a real car.
CLIENT_D = 0x2538CDC29A97C19C1E99A637D6CF4F8C970C118B56EDE1E6323E6D162C4B30DB
VEHICLE_D = 0x344EE5B466A7CF1EEB12B6F50331DB2E5EC5834EF5F4BEFCFD8CBE55C2528D70
VIN = b"5YJ30123456789ABC"

client = ec.derive_private_key(CLIENT_D, ec.SECP256R1())
vehicle = ec.derive_private_key(VEHICLE_D, ec.SECP256R1())


def enc_pub(k):
    return k.public_key().public_bytes(
        serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint
    )


def tlv(tag, value):
    return bytes([tag, len(value)]) + value


def u32(n):
    return struct.pack(">I", n)


def metadata(items):
    return b"".join(tlv(t, v) for t, v in sorted(items)) + b"\xff"


# --- key agreement
shared_x = client.exchange(ec.ECDH(), vehicle.public_key())
K = hashlib.sha1(shared_x).digest()[:16]
print("K", K.hex())

# --- session info request (VCSEC domain)
ROUTING = bytes.fromhex("2c907bd76c640d360b3027dc7404efde")
UUID = bytes.fromhex("1588d5a30eabc6f8fc9a951b11f6fd11")
req = um.RoutableMessage()
req.to_destination.domain = um.DOMAIN_VEHICLE_SECURITY
req.from_destination.routing_address = ROUTING
req.session_info_request.public_key = enc_pub(client)
req.uuid = UUID
print("SESSION_INFO_REQUEST", req.SerializeToString().hex())

# --- session info response + HMAC
EPOCH = bytes.fromhex("4c463f9cc0d3d26906e982ed224adde6")
info = sig.SessionInfo()
info.counter = 6
info.publicKey = enc_pub(vehicle)
info.epoch = EPOCH
info.clock_time = 2650
info_bytes = info.SerializeToString()
print("SESSION_INFO", info_bytes.hex())
sik = hmac.new(K, b"session info", hashlib.sha256).digest()
md = metadata([(0, bytes([6])), (2, VIN), (6, UUID)])
tag = hmac.new(sik, md + info_bytes, hashlib.sha256).digest()
print("SESSION_INFO_TAG", tag.hex())

# --- signed command (unlock), AES-GCM, fixed nonce
NONCE = bytes.fromhex("dbf79447fa156674dae1caed")
EXPIRES = 2655
COUNTER = 7
FLAGS = 2  # 1 << FLAG_ENCRYPT_RESPONSE, as the official client sets


def signed_command(plaintext, domain, counter, expires, flags):
    items = [
        (0, bytes([5])),
        (1, bytes([domain])),
        (2, VIN),
        (3, EPOCH),
        (4, u32(expires)),
        (5, u32(counter)),
    ]
    if flags:
        items.append((7, u32(flags)))
    aad = hashlib.sha256(metadata(items)).digest()
    ct = AESGCM(K).encrypt(NONCE, plaintext, aad)
    body, t = ct[:-16], ct[-16:]
    m = um.RoutableMessage()
    m.to_destination.domain = domain
    m.from_destination.routing_address = ROUTING
    m.protobuf_message_as_bytes = body
    m.signature_data.signer_identity.public_key = enc_pub(client)
    g = m.signature_data.AES_GCM_Personalized_data
    g.epoch = EPOCH
    g.nonce = NONCE
    g.counter = counter
    g.expires_at = expires
    g.tag = t
    m.uuid = UUID
    if flags:
        m.flags = flags
    return m.SerializeToString()


unlock = vc.UnsignedMessage()
unlock.RKEAction = vc.RKE_ACTION_UNLOCK
print("UNLOCK_PLAINTEXT", unlock.SerializeToString().hex())
print("UNLOCK_MESSAGE", signed_command(unlock.SerializeToString(), 2, COUNTER, EXPIRES, FLAGS).hex())

lock = vc.UnsignedMessage()
lock.RKEAction = vc.RKE_ACTION_LOCK
print("LOCK_PLAINTEXT", lock.SerializeToString().hex())

frunk = vc.UnsignedMessage()
frunk.closureMoveRequest.frontTrunk = vc.CLOSURE_MOVE_TYPE_MOVE
print("FRUNK_PLAINTEXT", frunk.SerializeToString().hex())

trunk = vc.UnsignedMessage()
trunk.closureMoveRequest.rearTrunk = vc.CLOSURE_MOVE_TYPE_MOVE
print("TRUNK_PLAINTEXT", trunk.SerializeToString().hex())

# --- add-key request (legacy ToVCSECMessage envelope, no signature)
add = vc.UnsignedMessage()
op = add.WhitelistOperation
op.addKeyToWhitelistAndAddPermissions.key.PublicKeyRaw = enc_pub(client)
op.addKeyToWhitelistAndAddPermissions.keyRole = keys.ROLE_DRIVER
op.metadataForKey.keyFormFactor = vc.KEY_FORM_FACTOR_IOS_DEVICE
env = vc.ToVCSECMessage()
env.signedMessage.protobufMessageAsBytes = add.SerializeToString()
env.signedMessage.signatureType = vc.SIGNATURE_TYPE_PRESENT_KEY
print("ADD_KEY_ENVELOPE", env.SerializeToString().hex())

# --- a FromVCSECMessage reply: commandStatus { operationStatus: WAIT }
fv = vc.FromVCSECMessage()
fv.commandStatus.operationStatus = vc.OPERATIONSTATUS_WAIT
print("FROM_VCSEC_WAIT", fv.SerializeToString().hex())
fv2 = vc.FromVCSECMessage()
fv2.commandStatus.whitelistOperationStatus.operationStatus = vc.OPERATIONSTATUS_OK
print("FROM_VCSEC_WL_OK", fv2.SerializeToString().hex())

# --- encrypted VCSEC response to the unlock request above
unlock_msg = um.RoutableMessage()
unlock_msg.ParseFromString(signed_command(unlock.SerializeToString(), 2, COUNTER, EXPIRES, FLAGS))
req_hash = bytes([5]) + unlock_msg.signature_data.AES_GCM_Personalized_data.tag  # 17 bytes
print("REQUEST_HASH", req_hash.hex())
RESP_NONCE = bytes.fromhex("0102030405060708090a0b0c")
RESP_COUNTER = 8
RESP_FLAGS = 2
resp_md = metadata([
    (0, bytes([9])), (1, bytes([2])), (2, VIN), (5, u32(RESP_COUNTER)),
    (7, u32(RESP_FLAGS)), (8, req_hash), (9, u32(0)),
])
resp_plain = vc.FromVCSECMessage().SerializeToString()  # empty message == success
resp_ct = AESGCM(K).encrypt(RESP_NONCE, resp_plain or b"", hashlib.sha256(resp_md).digest())
resp = um.RoutableMessage()
resp.to_destination.routing_address = ROUTING
resp.from_destination.domain = um.DOMAIN_VEHICLE_SECURITY
resp.protobuf_message_as_bytes = resp_ct[:-16]
r = resp.signature_data.AES_GCM_Response_data
r.nonce = RESP_NONCE
r.counter = RESP_COUNTER
r.tag = resp_ct[-16:]
resp.flags = RESP_FLAGS
resp.request_uuid = UUID
print("ENCRYPTED_RESPONSE", resp.SerializeToString().hex())

# encrypted response carrying a WAIT command status
resp_plain2 = fv.SerializeToString()
resp_ct2 = AESGCM(K).encrypt(RESP_NONCE, resp_plain2, hashlib.sha256(resp_md).digest())
resp2 = um.RoutableMessage()
resp2.CopyFrom(resp)
resp2.protobuf_message_as_bytes = resp_ct2[:-16]
resp2.signature_data.AES_GCM_Response_data.tag = resp_ct2[-16:]
print("ENCRYPTED_RESPONSE_WAIT", resp2.SerializeToString().hex())
