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
                connectionFaultSection
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
            .onChange(of: controller.selectedRole) {
                controller.selectedRoleDidChange()
            }

            LabeledContent("狀態") {
                Label(controller.statusText, systemImage: statusSymbol)
                    .foregroundStyle(statusColor)
                    .multilineTextAlignment(.trailing)
            }

            LabeledContent("TCP", value: "127.0.0.1:\(controller.port)")
            LabeledContent("連線模式", value: controller.connectionScenario.title)

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

            Button(action: controller.testAttributeValueLimit) {
                Label("測試 513-byte Attribute", systemImage: "externaldrive.badge.exclamationmark")
            }

            Button(action: controller.testAdvertisingLimit) {
                Label("測試超過 31-byte Advertising", systemImage: "antenna.radiowaves.left.and.right.slash")
            }

            Button(action: controller.testInvalidBluetoothUUID) {
                Label("測試無效 BLE UUID", systemImage: "number.circle.fill")
            }

            Button(action: controller.testMissingReadPermission) {
                Label("測試 Read 缺少權限", systemImage: "lock.trianglebadge.exclamationmark")
            }
            .disabled(controller.selectedRole != .peripheral || !controller.isRunning)

            Button(action: controller.testUnsupportedNotification) {
                Label("測試不支援 Notification", systemImage: "bell.slash.fill")
            }
        }
    }

    private var connectionFaultSection: some View {
        Section {
            LabeledContent("目前情境") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(controller.connectionScenario.title)
                    Text(controller.connectionScenario.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }

            Button(action: controller.startNormalConnection) {
                Label("正常連線並重啟", systemImage: "arrow.clockwise.circle")
            }

            Button(action: controller.startPoorConnection) {
                Label("高延遲＋逐 byte 拆包並重啟", systemImage: "tortoise.fill")
            }

            Button(action: controller.startDisconnectDuringRead) {
                Label("Read 傳輸途中斷線並重啟", systemImage: "cable.connector.slash")
            }
            .disabled(controller.selectedRole != .central)
        } header: {
            Text("連線品質與斷線測試")
        } footer: {
            Text("劣質連線可在任一端啟用；Read 中斷情境需在 Central 執行，並會驗證 pending callback 與斷線事件。")
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
        case .passed: return .green
        case .error: return .red
        }
    }
}
