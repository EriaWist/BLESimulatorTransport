#if targetEnvironment(simulator)
import BluetoothMock
#else
import CoreBluetooth
#endif
import Foundation

final class ExamplePeripheral: NSObject, CBPeripheralManagerDelegate {
    private var manager: CBPeripheralManager!
    private let characteristic = CBMutableCharacteristic(
        type: CBUUID(string: "FFF1"),
        properties: [.read, .write, .notify],
        value: Data([0x01]),
        permissions: [.readable, .writeable]
    )

    override init() {
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: .main, options: Self.options)
    }

    private static var options: [String: Any]? {
        #if targetEnvironment(simulator)
        return [
            BluetoothMockOption.tcpPort: 7_799,
            BluetoothMockOption.attMTU: 247
        ]
        #else
        return nil
        #endif
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else { return }
        let service = CBMutableService(type: CBUUID(string: "FFF0"), primary: true)
        service.characteristics = [characteristic]
        peripheral.add(service)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard error == nil else { return }
        peripheral.startAdvertising([
            CBAdvertisementDataLocalNameKey: "Mock Device",
            CBAdvertisementDataServiceUUIDsKey: [service.uuid]
        ])
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        request.value = characteristic.value
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            characteristic.value = request.value
            peripheral.respond(to: request, withResult: .success)
        }
    }
}
