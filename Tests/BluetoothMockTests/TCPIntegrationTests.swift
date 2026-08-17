import XCTest
@testable import BluetoothMock

final class TCPIntegrationTests: XCTestCase {
    private final class CentralSpy: CBCentralManagerDelegate {
        var onState: ((CBCentralManager) -> Void)?
        var onDiscover: ((CBCentralManager, CBPeripheral) -> Void)?
        var onConnect: ((CBCentralManager, CBPeripheral) -> Void)?
        var onFailure: ((Error?) -> Void)?

        func centralManagerDidUpdateState(_ central: CBCentralManager) { onState?(central) }
        func centralManager(
            _ central: CBCentralManager,
            didDiscover peripheral: CBPeripheral,
            advertisementData: [String: Any],
            rssi RSSI: NSNumber
        ) { onDiscover?(central, peripheral) }
        func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
            onConnect?(central, peripheral)
        }
        func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
            onFailure?(error)
        }
    }

    private final class PeripheralManagerSpy: CBPeripheralManagerDelegate {
        var onState: ((CBPeripheralManager) -> Void)?
        var onAdd: ((Error?) -> Void)?
        var onAdvertising: ((Error?) -> Void)?

        func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) { onState?(peripheral) }
        func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
            onAdd?(error)
        }
        func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
            onAdvertising?(error)
        }
    }

    private final class RemotePeripheralSpy: CBPeripheralDelegate {
        var onServices: ((CBPeripheral, Error?) -> Void)?
        var onCharacteristics: ((CBPeripheral, CBService, Error?) -> Void)?
        var onValue: ((CBPeripheral, CBCharacteristic, Error?) -> Void)?
        var onWrite: ((CBPeripheral, CBCharacteristic, Error?) -> Void)?
        var onNotificationState: ((CBPeripheral, CBCharacteristic, Error?) -> Void)?

        func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
            onServices?(peripheral, error)
        }
        func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
            onCharacteristics?(peripheral, service, error)
        }
        func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
            onValue?(peripheral, characteristic, error)
        }
        func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
            onWrite?(peripheral, characteristic, error)
        }
        func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
            onNotificationState?(peripheral, characteristic, error)
        }
    }

    func testTwoEndpointsCompleteGATTFlowOverLocalhost() throws {
        let port = UInt16.random(in: 40_000...60_000)
        let options: [String: Any] = [
            BluetoothMockOption.tcpPort: NSNumber(value: port),
            BluetoothMockOption.attMTU: NSNumber(value: 23),
            BluetoothMockOption.automaticATTResponses: NSNumber(value: true)
        ]
        let peripheralPoweredOn = expectation(description: "peripheral powered on")
        let serviceAdded = expectation(description: "service added")
        let advertising = expectation(description: "advertising")
        let centralPoweredOn = expectation(description: "central powered on")
        let notificationReceived = expectation(description: "notification received")
        let unexpectedFailure = expectation(description: "no connection failure")
        unexpectedFailure.isInverted = true
        var advertisingError: Error?

        let peripheralSpy = PeripheralManagerSpy()
        let peripheralManager = CBPeripheralManager(delegate: peripheralSpy, queue: .main, options: options)
        peripheralSpy.onState = { manager in
            if manager.state == .poweredOn { peripheralPoweredOn.fulfill() }
        }
        wait(for: [peripheralPoweredOn], timeout: 2)

        let localCharacteristic = CBMutableCharacteristic(
            type: CBUUID(string: "2A37"),
            properties: [.read, .write, .notify],
            value: Data("initial".utf8),
            permissions: [.readable, .writeable]
        )
        let localService = CBMutableService(type: CBUUID(string: "180D"), primary: true)
        localService.characteristics = [localCharacteristic]
        peripheralSpy.onAdd = { error in
            XCTAssertNil(error)
            serviceAdded.fulfill()
        }
        peripheralManager.add(localService)
        wait(for: [serviceAdded], timeout: 2)

        peripheralSpy.onAdvertising = { error in
            advertisingError = error
            advertising.fulfill()
        }
        peripheralManager.startAdvertising([
            CBAdvertisementDataLocalNameKey: "Mock",
            CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: "180D")]
        ])
        wait(for: [advertising], timeout: 2)
        if let advertisingError {
            throw XCTSkip(
                "This environment does not allow a localhost TCP listener: \(advertisingError.localizedDescription)"
            )
        }

        let remoteSpy = RemotePeripheralSpy()
        let centralSpy = CentralSpy()
        centralSpy.onFailure = { _ in unexpectedFailure.fulfill() }
        let centralManager = CBCentralManager(delegate: centralSpy, queue: .main, options: options)
        centralSpy.onState = { manager in
            if manager.state == .poweredOn { centralPoweredOn.fulfill() }
        }
        centralSpy.onDiscover = { manager, peripheral in
            manager.stopScan()
            manager.connect(peripheral)
        }
        centralSpy.onConnect = { _, peripheral in
            peripheral.delegate = remoteSpy
            peripheral.discoverServices([CBUUID(string: "180D")])
        }
        remoteSpy.onServices = { peripheral, error in
            XCTAssertNil(error)
            XCTAssertEqual(peripheral.services?.count, 1)
            peripheral.discoverCharacteristics([CBUUID(string: "2A37")], for: peripheral.services![0])
        }
        remoteSpy.onCharacteristics = { peripheral, service, error in
            XCTAssertNil(error)
            XCTAssertEqual(service.characteristics?.count, 1)
            peripheral.readValue(for: service.characteristics![0])
        }
        remoteSpy.onValue = { peripheral, characteristic, error in
            XCTAssertNil(error)
            if characteristic.value == Data("initial".utf8) {
                peripheral.writeValue(Data("written".utf8), for: characteristic, type: .withResponse)
            } else if characteristic.value == Data("pushed".utf8) {
                notificationReceived.fulfill()
            }
        }
        remoteSpy.onWrite = { peripheral, characteristic, error in
            XCTAssertNil(error)
            peripheral.setNotifyValue(true, for: characteristic)
        }
        remoteSpy.onNotificationState = { _, characteristic, error in
            XCTAssertNil(error)
            XCTAssertTrue(characteristic.isNotifying)
            XCTAssertTrue(peripheralManager.updateValue(
                Data("pushed".utf8),
                for: localCharacteristic,
                onSubscribedCentrals: nil
            ))
        }

        wait(for: [centralPoweredOn], timeout: 2)
        centralManager.scanForPeripherals(withServices: [CBUUID(string: "180D")])
        wait(for: [notificationReceived, unexpectedFailure], timeout: 6)
        XCTAssertEqual(localCharacteristic.value, Data("pushed".utf8))

        centralManager.stopScan()
        peripheralManager.stopAdvertising()
    }
}
