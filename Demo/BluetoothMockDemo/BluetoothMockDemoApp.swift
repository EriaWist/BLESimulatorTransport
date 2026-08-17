import SwiftUI

@main
struct BluetoothMockDemoApp: App {
    @StateObject private var controller = BluetoothDemoController()

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
        }
    }
}
