import BluetoothMock
import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: BluetoothDemoController

    var body: some View {
        NavigationStack {
            Form {
                roleSection
                dataSection
                limitsSection
                logSection
            }
            .navigationTitle("BluetoothMock Demo")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清除紀錄", action: controller.clearLogs)
                }
            }
        }
    }

    private var roleSection: some View {
        Section("Simulator 角色") {
            Picker("角色", selection: $controller.selectedRole) {
                ForEach(DemoRole.allCases) { role in
                    Label(role.title, systemImage: role.systemImage).tag(role)
                }
            }
            .pickerStyle(.segmented)

            LabeledContent("狀態") {
                Label(controller.statusText, systemImage: statusSymbol)
                    .foregroundStyle(statusColor)
                    .multilineTextAlignment(.trailing)
            }

            LabeledContent("TCP", value: "127.0.0.1:\(controller.port)")

            HStack {
                Button(controller.isRunning ? "套用角色並重啟" : "啟動") {
                    controller.start()
                }
                .buttonStyle(.borderedProminent)

                if controller.isRunning {
                    Button("停止", role: .destructive) {
                        controller.stop()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var dataSection: some View {
        Section("GATT 資料") {
            TextField("UTF-8 payload", text: $controller.outboundText, axis: .vertical)
                .lineLimit(2...4)

            LabeledContent("最後收到", value: controller.receivedText)

            if controller.selectedRole == .central {
                HStack {
                    Button("Read", action: controller.readValue)
                    Button("Write", action: controller.sendValue)
                }
                .buttonStyle(.bordered)
                .disabled(!controller.isConnected)
            } else {
                Button("送出 Notification", action: controller.sendNotification)
                    .buttonStyle(.borderedProminent)
                    .disabled(!controller.isConnected)
            }
        }
    }

    private var limitsSection: some View {
        Section("BLE 限制") {
            LabeledContent("ATT MTU", value: "\(controller.attMTU) bytes")
            LabeledContent("單次 payload", value: "≤ \(controller.maximumPayloadLength) bytes")
            LabeledContent("Attribute value", value: "≤ \(BLELimits.maximumAttributeValueLength) bytes")

            Button("測試超過 MTU 的傳輸") {
                controller.testOversizedPayload()
            }
            .disabled(!controller.isConnected)
        }
    }

    private var logSection: some View {
        Section {
            if controller.logs.isEmpty {
                ContentUnavailableView(
                    "尚無事件",
                    systemImage: "waveform.path.ecg",
                    description: Text("啟動後會顯示 scan、GATT 與限制檢查事件。")
                )
            } else {
                ForEach(controller.logs) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: entry.kind.symbol)
                            .foregroundStyle(color(for: entry.kind))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.message)
                                .font(.callout)
                                .textSelection(.enabled)
                            Text(entry.timeText)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("事件紀錄")
        }
    }

    private var statusColor: Color {
        if controller.isConnected { return .green }
        if controller.isRunning { return .orange }
        return .secondary
    }

    private var statusSymbol: String {
        if controller.isConnected { return "checkmark.circle.fill" }
        if controller.isRunning { return "clock.fill" }
        return "stop.circle.fill"
    }

    private func color(for kind: DemoLogEntry.Kind) -> Color {
        switch kind {
        case .info: return .secondary
        case .sent: return .blue
        case .received: return .green
        case .error: return .red
        }
    }
}
