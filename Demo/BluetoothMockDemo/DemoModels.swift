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

struct DemoLogEntry: Identifiable {
    enum Kind {
        case info
        case sent
        case received
        case error

        var symbol: String {
            switch self {
            case .info: return "info.circle.fill"
            case .sent: return "arrow.up.circle.fill"
            case .received: return "arrow.down.circle.fill"
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
