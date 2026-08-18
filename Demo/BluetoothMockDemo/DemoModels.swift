import Foundation

enum DemoRole: String, CaseIterable, Identifiable {
    case peripheral
    case central

    var id: Self { self }

    var title: String {
        switch self {
        case .peripheral: return "Peripheral"
        case .central: return "Central"
        }
    }

    var systemImage: String {
        switch self {
        case .peripheral: return "antenna.radiowaves.left.and.right"
        case .central: return "dot.radiowaves.left.and.right"
        }
    }
}

enum DemoConnectionScenario: String {
    case normal
    case poorConnection
    case disconnectDuringRead

    var title: String {
        switch self {
        case .normal: return "正常"
        case .poorConnection: return "高延遲＋逐 byte 拆包"
        case .disconnectDuringRead: return "Read 傳輸中斷"
        }
    }

    var detail: String {
        switch self {
        case .normal:
            return "不注入網路故障"
        case .poorConnection:
            return "每個 frame 延遲 80 ms，並拆成 1-byte TCP send"
        case .disconnectDuringRead:
            return "Central 送出第 6 個 frame（Read）後中斷"
        }
    }
}

struct DemoLogEntry: Identifiable {
    enum Kind {
        case info
        case sent
        case received
        case passed
        case error

        var symbol: String {
            switch self {
            case .info: return "info.circle.fill"
            case .sent: return "arrow.up.circle.fill"
            case .received: return "arrow.down.circle.fill"
            case .passed: return "checkmark.seal.fill"
            case .error: return "exclamationmark.triangle.fill"
            }
        }
    }

    let id = UUID()
    let time = Date()
    let kind: Kind
    let message: String

    var timeText: String {
        time.formatted(date: .omitted, time: .standard)
    }
}
