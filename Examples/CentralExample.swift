#if targetEnvironment(simulator)
import BluetoothMock
#else
import CoreBluetooth
#endif
import Foundation

final class ExampleCentral: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var manager: CBCentralManager!

    override init() {
        super.init()
        manager = CBCentralManager(delegate: self, queue: .main, options: Self.options)
    }

    private static var options: [String: Any]? {
        #if targetEnvironment(simulator)
        return [
            BluetoothMockOption.tcpHost: "127.0.0.1",
            BluetoothMockOption.tcpPort: 7_799,
            BluetoothMockOption.attMTU: 247
        ]
        #else
        return nil
        #endif
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: [CBUUID(string: "FFF0")])
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        central.stopScan()
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([CBUUID(string: "FFF0")])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first else { return }
        peripheral.discoverCharacteristics([CBUUID(string: "FFF1")], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil, let characteristic = service.characteristics?.first else { return }
        peripheral.readValue(for: characteristic)
        peripheral.setNotifyValue(true, for: characteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let data = characteristic.value else { return }
        print("received", data as NSData)
    }
}
