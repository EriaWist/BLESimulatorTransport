@preconcurrency import BluetoothMock
import Foundation

@MainActor
final class BluetoothDemoController: NSObject, ObservableObject {
    static let serviceUUID = CBUUID(string: "FFF0")
    static let characteristicUUID = CBUUID(string: "FFF1")

    let port: UInt16 = 7_799
    let attMTU = 247

    @Published var selectedRole: DemoRole = .peripheral
    @Published var outboundText = "Hello BLE"
    @Published private(set) var receivedText = "—"
    @Published private(set) var statusText = "尚未啟動"
    @Published private(set) var isRunning = false
    @Published private(set) var isConnected = false
    @Published private(set) var logs: [DemoLogEntry] = []

    var maximumPayloadLength: Int {
        BLELimits.maximumAttributePayload(forATTMTU: attMTU)
    }

    private var centralManager: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var remotePeripheral: CBPeripheral?
    private var remoteCharacteristic: CBCharacteristic?
    private var localCharacteristic: CBMutableCharacteristic?

    private var options: [String: Any] {
        [
            BluetoothMockOption.tcpHost: "127.0.0.1",
            BluetoothMockOption.tcpPort: NSNumber(value: port),
            BluetoothMockOption.attMTU: NSNumber(value: attMTU),
            BluetoothMockOption.rssi: NSNumber(value: -48),
            BluetoothMockOption.peripheralIdentifier: "D729FA79-9F15-4F25-94C7-28E50A462219"
        ]
    }

    func start() {
        stop(addLog: false)
        isRunning = true
        receivedText = "—"
        append(.info, "以 \(selectedRole.title) 模式啟動")

        switch selectedRole {
        case .peripheral:
            statusText = "正在準備 GATT…"
            peripheralManager = CBPeripheralManager(delegate: self, queue: .main, options: options)
        case .central:
            statusText = "正在啟動 Central…"
            centralManager = CBCentralManager(delegate: self, queue: .main, options: options)
        }
    }

    func stop() {
        stop(addLog: true)
    }

    func clearLogs() {
        logs.removeAll()
    }

    func readValue() {
        guard let remotePeripheral, let remoteCharacteristic else {
            append(.error, "尚未找到可讀 characteristic")
            return
        }
        append(.sent, "Read request")
        remotePeripheral.readValue(for: remoteCharacteristic)
    }

    func sendValue() {
        guard let data = outboundText.data(using: .utf8) else { return }
        send(data)
    }

    func sendNotification() {
        guard let peripheralManager, let localCharacteristic else {
            append(.error, "Peripheral 尚未完成 GATT 設定")
            return
        }
        let data = Data(outboundText.utf8)
        if peripheralManager.updateValue(data, for: localCharacteristic, onSubscribedCentrals: nil) {
            append(.sent, "Notify \(data.count) bytes：\(outboundText)")
        } else {
            append(.error, "Notify 被拒絕：\(data.count) bytes 超過限制或尚未訂閱")
        }
    }

    func testOversizedPayload() {
        let data = Data(repeating: 0x41, count: maximumPayloadLength + 1)
        append(.info, "測試超限 payload：\(data.count) bytes（上限 \(maximumPayloadLength)）")

        switch selectedRole {
        case .central:
            send(data)
        case .peripheral:
            guard let peripheralManager, let localCharacteristic else {
                append(.error, "Peripheral 尚未完成 GATT 設定")
                return
            }
            let accepted = peripheralManager.updateValue(
                data,
                for: localCharacteristic,
                onSubscribedCentrals: nil
            )
            append(
                accepted ? .sent : .error,
                accepted ? "超限 notify 意外被接受" : "正確拒絕超過 MTU 的 notify"
            )
        }
    }

    private func send(_ data: Data) {
        guard let remotePeripheral, let remoteCharacteristic else {
            append(.error, "Central 尚未連線或找不到 characteristic")
            return
        }
        append(.sent, "Write request：\(data.count) bytes")
        remotePeripheral.writeValue(data, for: remoteCharacteristic, type: .withResponse)
    }

    private func stop(addLog: Bool) {
        centralManager?.stopScan()
        if let remotePeripheral, remotePeripheral.state != .disconnected {
            centralManager?.cancelPeripheralConnection(remotePeripheral)
        }
        peripheralManager?.stopAdvertising()
        peripheralManager?.removeAllServices()

        centralManager = nil
        peripheralManager = nil
        remotePeripheral = nil
        remoteCharacteristic = nil
        localCharacteristic = nil
        isRunning = false
        isConnected = false
        statusText = "已停止"
        if addLog { append(.info, "已停止") }
    }

    private func append(_ kind: DemoLogEntry.Kind, _ message: String) {
        logs.insert(DemoLogEntry(kind: kind, message: message), at: 0)
        if logs.count > 100 { logs.removeLast(logs.count - 100) }
    }
}

// MARK: - Central

extension BluetoothDemoController: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        append(.info, "Central state：\(central.state)")
        guard central.state == .poweredOn else {
            statusText = "Central 無法啟動"
            return
        }
        statusText = "掃描 FFF0…"
        append(.sent, "開始 scan，service = FFF0")
        central.scanForPeripherals(withServices: [Self.serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "Unknown"
        append(.received, "發現 \(name)，RSSI \(RSSI) dBm")
        statusText = "正在連線…"
        central.stopScan()
        remotePeripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnected = true
        statusText = "已連線，探索 GATT…"
        append(.received, "已連線；協商 write payload 上限 \(peripheral.maximumWriteValueLength(for: .withResponse)) bytes")
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        isConnected = false
        statusText = "連線失敗"
        append(.error, "連線失敗：\(error?.localizedDescription ?? "unknown")")
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        isConnected = false
        statusText = "已斷線"
        append(.info, "已斷線\(error.map { "：\($0.localizedDescription)" } ?? "")")
    }
}

extension BluetoothDemoController: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first else {
            append(.error, "Service discovery 失敗：\(error?.localizedDescription ?? "找不到 FFF0")")
            return
        }
        append(.received, "找到 service \(service.uuid)")
        peripheral.discoverCharacteristics([Self.characteristicUUID], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil, let characteristic = service.characteristics?.first else {
            append(.error, "Characteristic discovery 失敗：\(error?.localizedDescription ?? "找不到 FFF1")")
            return
        }
        remoteCharacteristic = characteristic
        statusText = "已連線，可開始操作"
        append(.received, "找到 characteristic \(characteristic.uuid)")
        peripheral.setNotifyValue(true, for: characteristic)
        readValue()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            append(.error, "Value update 失敗：\(error.localizedDescription)")
            return
        }
        let data = characteristic.value ?? Data()
        receivedText = String(data: data, encoding: .utf8) ?? data.map { String(format: "%02X", $0) }.joined(separator: " ")
        append(.received, "收到 \(data.count) bytes：\(receivedText)")
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            append(.error, "Write 被拒絕：\(error.localizedDescription)")
        } else {
            append(.received, "Write response：success")
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            append(.error, "訂閱失敗：\(error.localizedDescription)")
        } else {
            append(.received, characteristic.isNotifying ? "已訂閱 notification" : "已取消訂閱")
        }
    }
}

// MARK: - Peripheral

extension BluetoothDemoController: @preconcurrency CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        append(.info, "Peripheral state：\(peripheral.state)")
        guard peripheral.state == .poweredOn else {
            statusText = "Peripheral 無法啟動"
            return
        }

        let characteristic = CBMutableCharacteristic(
            type: Self.characteristicUUID,
            properties: [.read, .write, .notify],
            value: Data("Peripheral ready".utf8),
            permissions: [.readable, .writeable]
        )
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [characteristic]
        localCharacteristic = characteristic
        peripheral.add(service)
        statusText = "正在加入 GATT service…"
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didAdd service: CBService,
        error: Error?
    ) {
        guard error == nil else {
            statusText = "GATT 設定失敗"
            append(.error, "加入 service 失敗：\(error!.localizedDescription)")
            return
        }
        append(.info, "已加入 service \(service.uuid)")
        peripheral.startAdvertising([
            CBAdvertisementDataLocalNameKey: "BluetoothMock Demo",
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID]
        ])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            statusText = "Advertising 失敗"
            append(.error, error.localizedDescription)
        } else {
            statusText = "Advertising：127.0.0.1:\(port)"
            append(.sent, "開始 advertising，等待 Central")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        request.value = localCharacteristic?.value
        peripheral.respond(to: request, withResult: .success)
        append(.received, "收到 read request，回覆 \(request.value?.count ?? 0) bytes")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            localCharacteristic?.value = request.value
            receivedText = request.value.flatMap { String(data: $0, encoding: .utf8) } ?? "binary data"
            peripheral.respond(to: request, withResult: .success)
            append(.received, "收到 write：\(request.value?.count ?? 0) bytes，回覆 success")
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        isConnected = true
        statusText = "Central 已連線並訂閱"
        append(.received, "Central 訂閱 FFF1；notify 上限 \(central.maximumUpdateValueLength) bytes")
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        isConnected = false
        statusText = "Central 已取消訂閱"
        append(.info, "Central 已取消訂閱 FFF1")
    }
}
