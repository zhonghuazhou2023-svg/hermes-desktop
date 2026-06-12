import SwiftUI

enum FleetSpacing {
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
}

enum FleetColor {
    static let statusGreen = Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255)
    static let statusOrange = Color(red: 1, green: 0x95 / 255, blue: 0)
    static let statusRed = Color(red: 1, green: 0x3B / 255, blue: 0x30 / 255)
    static let cardFill = Color.primary.opacity(0.04)
    static let card = cardFill
    static let cardRadius: CGFloat = 8
    static let content = Color(nsColor: .windowBackgroundColor)
    static let sidebarSelected = Color.accentColor.opacity(0.12)
    static let rowHover = Color.primary.opacity(0.05)
}

enum WorkshopRowLayout {
    static let spacing: CGFloat = FleetSpacing.sm
    static let chevronWidth: CGFloat = 12
    static let nameWidth: CGFloat = 108
    static let statusWidth: CGFloat = 28
    static let metricsTotalWidth: CGFloat = 210
    static let metricSpacing: CGFloat = FleetSpacing.xs
    static var metricColumnWidth: CGFloat { (metricsTotalWidth - metricSpacing * 2) / 3 }
    static let dwWidth: CGFloat = 56
    static let modelMinWidth: CGFloat = 80
    static let modelMaxWidth: CGFloat = 100
    static let ipWidth: CGFloat = 108
}

enum FileSizeFormat {
    static func string(bytes: Int?) -> String {
        guard let bytes, bytes >= 0 else { return "-" }
        let d = Double(bytes)
        if d < 1024 { return "\(bytes) B" }
        if d < 1024 * 1024 { return String(format: "%.1f KB", d / 1024) }
        if d < 1024 * 1024 * 1024 { return String(format: "%.1f MB", d / 1024 / 1024) }
        return String(format: "%.1f GB", d / 1024 / 1024 / 1024)
    }

    static func display(_ file: RepoFile) -> String {
        if let bytes = file.size { return string(bytes: bytes) }
        return file.size_human ?? "-"
    }
}

struct PageHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 16, weight: .bold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, FleetSpacing.md)
            .padding(.top, FleetSpacing.sm)
            .padding(.bottom, FleetSpacing.xs)
    }
}

struct StatusDot: View {
    let status: String
    @State private var pulse = false

    private var color: Color {
        switch status {
        case "critical": return FleetColor.statusRed
        case "warning": return FleetColor.statusOrange
        default: return FleetColor.statusGreen
        }
    }

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.25)).frame(width: pulse ? 20 : 14, height: pulse ? 20 : 14)
                .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: pulse)
            Circle().fill(color).frame(width: 12, height: 12)
        }
        .frame(width: 28, height: 28)
        .onAppear { pulse = true }
    }
}

struct MetricBar: View {
    let label: String
    let value: Double

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text("\(label) \(Int(value))%").font(.system(.caption, design: .monospaced)).monospacedDigit()
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.gray.opacity(0.2)).frame(height: 6)
                    RoundedRectangle(cornerRadius: 2).fill(barColor)
                        .frame(width: g.size.width * min(value / 100, 1), height: 6)
                }
            }
            .frame(height: 6)
        }
    }

    private var barColor: Color {
        value > 90 ? FleetColor.statusRed : value > 75 ? FleetColor.statusOrange : FleetColor.statusGreen
    }
}

struct StatCard: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundColor(.secondary)
            Text(value).font(.system(size: 20, weight: .semibold, design: .monospaced))
                .foregroundColor(color).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(FleetSpacing.sm)
        .background(FleetColor.cardFill)
        .cornerRadius(8)
    }
}

struct CompactMetricCell: View {
    let label: String
    let value: Double
    let color: Color

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text("\(label) \(Int(value))%")
                .font(.system(.caption2, design: .monospaced))
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.gray.opacity(0.15))
                    RoundedRectangle(cornerRadius: 2).fill(barColor)
                        .frame(width: g.size.width * min(value / 100, 1))
                }
            }
            .frame(height: 5)
        }
    }

    private var barColor: Color {
        if value > 90 { return FleetColor.statusRed }
        if value > 75 { return FleetColor.statusOrange }
        return color
    }
}

struct NodeRoleBadge: View {
    let role: WorkshopNodeRole

    var body: some View {
        Text(role.rawValue)
            .font(.system(size: 10))
            .foregroundColor(role.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(role.color.opacity(0.12))
            .cornerRadius(4)
    }
}

struct DWCapsule: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.system(.caption2, design: .monospaced))
            .foregroundColor(.white)
            .monospacedDigit()
            .padding(.horizontal, FleetSpacing.xs)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.accentColor))
            .frame(minWidth: 28)
    }
}

struct DWHealthTrend: View {
    let workers: [DigitalWorker]
    @ObservedObject var store: FleetStore
    let workshop: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(trendStates.enumerated()), id: \.offset) { _, state in
                Circle().fill(state.color).frame(width: 6, height: 6)
            }
        }
    }

    private var trendStates: [DWRunState] {
        guard let dw = workers.first else {
            return Array(repeating: .disconnected, count: 5)
        }
        var hist = store.dwHistory(for: workshop, dw: dw.name)
        while hist.count < 5 { hist.insert(.disconnected, at: 0) }
        return Array(hist.suffix(5))
    }
}

struct DWStatusBadge: View {
    let dw: DigitalWorker
    let failStreak: Int

    private var runState: DWRunState { DWRunState.from(dw) }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(runState.color).frame(width: 8, height: 8)
            Text(dw.name).font(.caption)
            Text(runState.rawValue).font(.caption2).foregroundColor(runState.color)
        }
        .help("上次巡检: \(dw.last_run ?? "-")\n连续失败: \(failStreak) 次")
    }
}

struct StageIndicator: View {
    let stages: [String]
    let stageLabels: [String]
    let currentStage: String
    let status: String

    @State private var pulse = false

    private var currentIndex: Int { stages.firstIndex(of: currentStage) ?? 0 }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(stages.enumerated()), id: \.offset) { idx, _ in
                if idx > 0 {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.7))
                }
                stageNode(at: idx)
            }
        }
        .onAppear { pulse = true }
    }

    @ViewBuilder
    private func stageNode(at idx: Int) -> some View {
        let label = idx < stageLabels.count ? stageLabels[idx] : stages[idx]
        VStack(spacing: 2) {
            if isCompleted(idx) {
                ZStack {
                    Circle().fill(FleetColor.statusGreen).frame(width: 14, height: 14)
                    Image(systemName: "checkmark").font(.system(size: 7, weight: .bold)).foregroundColor(.white)
                }
            } else if idx == currentIndex {
                activeNode
            } else {
                Circle().strokeBorder(Color.gray.opacity(0.45), lineWidth: 1.5).frame(width: 14, height: 14)
            }
            Text(label).font(.system(size: 8)).foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var activeNode: some View {
        if status == "failed" {
            ZStack {
                Circle().fill(FleetColor.statusRed).frame(width: 14, height: 14)
                Image(systemName: "xmark").font(.system(size: 7, weight: .bold)).foregroundColor(.white)
            }
        } else if status == "retrying" {
            ZStack {
                Circle().fill(FleetColor.statusOrange).frame(width: 14, height: 14)
                Image(systemName: "arrow.clockwise").font(.system(size: 7, weight: .bold)).foregroundColor(.white)
            }
        } else if status == "paused" {
            ZStack {
                Circle().fill(Color.yellow).frame(width: 14, height: 14)
                Image(systemName: "pause.fill").font(.system(size: 6, weight: .bold)).foregroundColor(.white)
            }
        } else {
            ZStack {
                Circle().fill(Color.blue.opacity(0.25))
                    .frame(width: pulse ? 20 : 16, height: pulse ? 20 : 16)
                    .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: pulse)
                Circle().fill(Color.blue).frame(width: 14, height: 14)
            }
        }
    }

    private func isCompleted(_ idx: Int) -> Bool {
        if status == "completed" { return true }
        return idx < currentIndex
    }
}

struct TaskControlButtons: View {
    let task: DAGTask
    let fleetReachable: Bool
    var onRetry: () -> Void
    var onPause: () -> Void
    var onResume: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if task.status == "failed" || task.status == "completed" {
                Button("🔄") { onRetry() }.buttonStyle(.borderless).help("重试").disabled(!fleetReachable)
            }
            if task.status == "running" {
                Button("⏸") { onPause() }.buttonStyle(.borderless).help("暂停").disabled(!fleetReachable)
            }
            if task.status == "paused" {
                Button("▶") { onResume() }.buttonStyle(.borderless).help("继续").disabled(!fleetReachable)
            }
        }
    }
}

struct CardBackground: ViewModifier {
    var borderColor: Color = .clear

    func body(content: Content) -> some View {
        content
            .padding(FleetSpacing.sm)
            .background(FleetColor.cardFill)
            .cornerRadius(FleetColor.cardRadius)
            .overlay(
                RoundedRectangle(cornerRadius: FleetColor.cardRadius)
                    .stroke(borderColor, lineWidth: borderColor == .clear ? 0 : 2)
            )
    }
}

extension View {
    func fleetCardStyle(border: Color = .clear) -> some View {
        modifier(CardBackground(borderColor: border))
    }

    func cardStyle(border: Color = .clear) -> some View {
        fleetCardStyle(border: border)
    }
}
