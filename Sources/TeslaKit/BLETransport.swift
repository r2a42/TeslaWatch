#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation

enum TeslaBLE {
    static let service = CBUUID(string: "00000211-B2D1-43F0-9B88-960CEBF8B91E")
    static let writeCharacteristic = CBUUID(string: "00000212-B2D1-43F0-9B88-960CEBF8B91E")
    static let readCharacteristic = CBUUID(string: "00000213-B2D1-43F0-9B88-960CEBF8B91E")

}

/// One BLE connection to one car. All mutable state lives on `queue`; the async API hops onto it.
final class BLETransport: NSObject {
    private let queue = DispatchQueue(label: "TeslaKit.BLE")

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var readChar: CBCharacteristic?
    private var targetName = ""
    private var disconnected = false

    private var frames = BLEFrameBuffer()
    private var inbox = [Data]()

    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var connectTimer: DispatchWorkItem?
    private var writeContinuation: CheckedContinuation<Void, Error>?
    private var receiveContinuation: CheckedContinuation<Data, Error>?
    private var receiveTimer: DispatchWorkItem?

    // MARK: Public (async) API

    /// Scans for the car's advertisement, connects and subscribes to replies.
    func connect(advertisedName: String, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                self.targetName = advertisedName
                self.connectContinuation = cont
                let timer = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.finishConnect(.failure(self.peripheral == nil ? TeslaError.vehicleNotFound : TeslaError.timeout))
                    self.teardown()
                }
                self.connectTimer = timer
                self.queue.asyncAfter(deadline: .now() + timeout, execute: timer)
                self.central = CBCentralManager(delegate: self, queue: self.queue)
            }
        }
    }

    func send(_ message: Data) async throws {
        let (peripheral, characteristic, chunkSize) = try await onQueue { () throws -> (CBPeripheral, CBCharacteristic, Int) in
            guard !self.disconnected, let p = self.peripheral, let c = self.writeChar else {
                throw TeslaError.protocolError("not connected")
            }
            return (p, c, max(20, p.maximumWriteValueLength(for: .withResponse)))
        }
        for chunk in BLEFrameBuffer.chunks(of: BLEFrameBuffer.frame(message), size: chunkSize) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                queue.async {
                    guard !self.disconnected else {
                        cont.resume(throwing: TeslaError.protocolError("disconnected"))
                        return
                    }
                    self.writeContinuation = cont
                    peripheral.writeValue(chunk, for: characteristic, type: .withResponse)
                }
            }
        }
    }

    /// Next complete message from the car.
    func receive(timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            queue.async {
                if !self.inbox.isEmpty {
                    cont.resume(returning: self.inbox.removeFirst())
                    return
                }
                if self.disconnected {
                    cont.resume(throwing: TeslaError.protocolError("disconnected"))
                    return
                }
                self.receiveContinuation = cont
                let timer = DispatchWorkItem { [weak self] in
                    guard let self, let c = self.receiveContinuation else { return }
                    self.receiveContinuation = nil
                    c.resume(throwing: TeslaError.timeout)
                }
                self.receiveTimer = timer
                self.queue.asyncAfter(deadline: .now() + timeout, execute: timer)
            }
        }
    }

    func disconnect() {
        queue.async { self.teardown() }
    }

    // MARK: Queue-confined helpers

    private func onQueue<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            queue.async { cont.resume(with: Result { try body() }) }
        }
    }

    private func finishConnect(_ result: Result<Void, Error>) {
        connectTimer?.cancel()
        connectTimer = nil
        guard let cont = connectContinuation else { return }
        connectContinuation = nil
        cont.resume(with: result)
    }

    private func teardown() {
        guard !disconnected else { return }
        disconnected = true
        central?.stopScan()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        let error = TeslaError.protocolError("disconnected")
        finishConnect(.failure(error))
        if let c = writeContinuation { writeContinuation = nil; c.resume(throwing: error) }
        receiveTimer?.cancel()
        if let c = receiveContinuation { receiveContinuation = nil; c.resume(throwing: error) }
    }

    private func deliver(_ message: Data) {
        if let c = receiveContinuation {
            receiveTimer?.cancel()
            receiveContinuation = nil
            c.resume(returning: message)
        } else {
            inbox.append(message)
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLETransport: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            central.scanForPeripherals(withServices: nil, options: nil)
        case .unauthorized:
            finishConnect(.failure(TeslaError.bluetoothUnavailable("permission denied")))
        case .poweredOff:
            finishConnect(.failure(TeslaError.bluetoothUnavailable("Bluetooth is off")))
        case .unsupported:
            finishConnect(.failure(TeslaError.bluetoothUnavailable("not supported")))
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        guard name == targetName, self.peripheral == nil else { return }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([TeslaBLE.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finishConnect(.failure(TeslaError.protocolError("connection failed")))
        teardown()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        teardown()
    }
}

// MARK: - CBPeripheralDelegate

extension BLETransport: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == TeslaBLE.service }) else {
            finishConnect(.failure(TeslaError.protocolError("vehicle service not found")))
            teardown()
            return
        }
        peripheral.discoverCharacteristics([TeslaBLE.writeCharacteristic, TeslaBLE.readCharacteristic], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        writeChar = service.characteristics?.first { $0.uuid == TeslaBLE.writeCharacteristic }
        readChar = service.characteristics?.first { $0.uuid == TeslaBLE.readCharacteristic }
        guard error == nil, writeChar != nil, let readChar else {
            finishConnect(.failure(TeslaError.protocolError("vehicle characteristics not found")))
            teardown()
            return
        }
        peripheral.setNotifyValue(true, for: readChar)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if error == nil, characteristic.isNotifying {
            finishConnect(.success(()))
        } else {
            finishConnect(.failure(TeslaError.protocolError("could not subscribe to replies")))
            teardown()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let chunk = characteristic.value else { return }
        for message in frames.append(chunk) { deliver(message) }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let cont = writeContinuation else { return }
        writeContinuation = nil
        if error == nil {
            cont.resume()
        } else {
            cont.resume(throwing: TeslaError.protocolError("write failed"))
        }
    }
}
#endif
