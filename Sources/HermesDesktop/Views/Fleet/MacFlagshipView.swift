import SwiftUI

struct MacFlagshipView: View {
    @ObservedObject var store: FleetStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Mac 旗舰").font(.title2).bold()

                GroupBox(label: Label("📊 今日画像", systemImage: "chart.bar.fill")) {
                    VStack(spacing: 8) {
                        FlagRow(icon: "brain.head.profile", label: "DeepSeek 用量", value: store.deepseekDailyTokens)
                        FlagRow(icon: "message.fill", label: "今日对话", value: "\(store.sessionCount) 轮")
                    }
                    .padding(8)
                }

                GroupBox(label: Label("🖥️ GPU 服务器 · RTX PRO 6000", systemImage: "server.rack")) {
                    VStack(spacing: 6) {
                        HStack {
                            Circle().fill(store.gpuOnline ? Color.green : Color.red).frame(width: 8, height: 8)
                            Text(store.gpuOnline ? "在线" : "离线").font(.callout)
                            Spacer()
                            Text(store.gpuTunnelActive ? "隧道已通" : "未连接")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        if store.gpuTunnelActive {
                            Text(store.gpuLocalUrl).font(.caption).foregroundColor(.accentColor)
                        }
                        HStack {
                            if !store.gpuTunnelActive {
                                Button("🔗 连接") { Task { await store.connectGPU() } }
                            } else {
                                Button("🔌 断开") { Task { await store.disconnectGPU() } }
                            }
                            Button("🔄") { Task { await store.loadGPUStatus() } }.help("刷新状态")
                        }
                    }
                    .padding(8)
                }
            }
            .padding()
        }
        .background(FleetColor.content)
        .task { await store.loadUsage() }
    }
}

struct FlagRow: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack {
            Image(systemName: icon).frame(width: 20).foregroundColor(.secondary)
            Text(label).font(.callout)
            Spacer()
            Text(value).font(.callout).foregroundColor(.secondary)
        }
    }
}
