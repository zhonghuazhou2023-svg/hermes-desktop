import SwiftUI

enum FleetTab: String, CaseIterable {
    case overview = "车间总览"
    case dag = "流水线DAG"
    case tasks = "任务分派"
    case flagship = "Mac旗舰"

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .dag: return "arrow.triangle.branch"
        case .tasks: return "paperplane"
        case .flagship: return "macbook.and.iphone"
        }
    }
}

struct FleetView: View {
    @StateObject private var store = FleetStore()
    @State private var tab: FleetTab = .overview
    @State private var timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    ForEach(FleetTab.allCases, id: \.self) { t in
                        Label(t.rawValue, systemImage: t.icon).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 520)
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(store.fleetReachable ? Color.green : Color.red).frame(width: 8, height: 8)
                    Text(store.fleetReachable ? "已连接" : "未连接").font(.caption).foregroundColor(.secondary)
                }
                Button { Task { await store.loadStatus() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()
            Group {
                switch tab {
                case .overview: WorkshopOverviewView(store: store)
                case .dag: DAGPipelineView(store: store)
                case .tasks: TaskDispatchView(store: store)
                case .flagship: MacFlagshipView(store: store)
                }
            }
        }
        .onReceive(timer) { _ in Task { await store.loadStatus() } }
        .task { await store.loadStatus() }
    }
}
