import SwiftUI

struct OrchestraView: View {
    @State private var agents: [AgentCapability] = []
    @State private var selectedAgent: AgentCapability?

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Agent Orchestra").font(.system(size: 16, weight: .bold))
                    Spacer()
                    if !agents.isEmpty {
                        Text("\(agents.count) agents").font(.caption).foregroundColor(.secondary)
                    }
                    Button { Task { await load() } } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium))
                    }.buttonStyle(.borderless)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)

                Divider()

                if agents.isEmpty {
                    Spacer()
                    Text("无法连接 factory (:8788)").foregroundColor(.secondary)
                    Spacer()
                } else {
                    List(selection: $selectedAgent) {
                        ForEach(agents) { agent in
                            AgentCard(agent: agent).tag(agent)
                        }
                    }
                    .listStyle(.inset)
                }
            }
        } detail: {
            if let agent = selectedAgent {
                AgentDetail(agent: agent)
            } else {
                EmptyOrchestra()
            }
        }
        .task { await load() }
    }

    private func load() async {
        agents = await OrchestraService.loadAgents()
    }
}

struct AgentCard: View {
    let agent: AgentCapability

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: agent.roleIcon)
                    .font(.system(size: 16))
                    .foregroundColor(.accentColor)
                    .frame(width: 24, height: 24)
                Text(agent.name).font(.headline).lineLimit(1)
                Spacer()
                Circle().fill(statusColor).frame(width: 8, height: 8)
            }
            HStack {
                Text(agent.roleLabel).font(.caption).foregroundColor(.secondary)
                Spacer()
                Text(agent.model).font(.caption2).foregroundColor(.secondary)
            }
            HStack(spacing: 4) {
                Text("负载").font(.caption2).foregroundColor(.secondary)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.gray.opacity(0.2)).frame(height: 4)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(loadColor)
                            .frame(width: geometry.size.width * min(agent.loadPct / 100, 1), height: 4)
                    }
                }.frame(height: 4)
                Text("\(Int(agent.loadPct))%")
                    .font(.caption2).monospacedDigit().foregroundColor(.secondary).frame(width: 32)
            }
            if !agent.specializations.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(agent.specializations.prefix(3), id: \.self) { spec in
                            Text(spec).font(.system(size: 9)).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.1)).cornerRadius(4)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var statusColor: Color {
        switch agent.status {
        case "critical": return .red
        case "warning": return .orange
        default: return .green
        }
    }

    private var loadColor: Color {
        agent.loadPct > 80 ? .red : agent.loadPct > 50 ? .orange : .green
    }
}

struct AgentDetail: View {
    let agent: AgentCapability

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: agent.roleIcon).font(.system(size: 32)).foregroundColor(.accentColor)
                        VStack(alignment: .leading) {
                            Text(agent.name).font(.title2).bold()
                            Text(agent.roleLabel).font(.subheadline).foregroundColor(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Circle().fill(statusColor).frame(width: 12, height: 12)
                            Text(agent.status).font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }
                .padding(16).background(Color.primary.opacity(0.04)).cornerRadius(8)

                HStack(spacing: 12) {
                    MiniMetric(label: "CPU", value: "\(Int(agent.cpuPct))%", color: agent.cpuPct > 80 ? .red : .green)
                    MiniMetric(label: "内存", value: "\(Int(agent.memoryPct))%", color: agent.memoryPct > 80 ? .red : .green)
                    MiniMetric(label: "磁盘", value: "\(Int(agent.diskPct))%", color: agent.diskPct > 80 ? .red : .green)
                    MiniMetric(label: "任务", value: agent.hasDagTask ? "执行中" : "空闲", color: agent.hasDagTask ? .blue : .secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("模型与能力").font(.headline)
                    HStack {
                        Label(agent.model, systemImage: "cpu").font(.caption)
                        Spacer()
                        Label(agent.capabilities.summary, systemImage: "gearshape.2").font(.caption)
                    }
                    .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("专长领域").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 4) {
                        ForEach(agent.specializations, id: \.self) { spec in
                            Label(spec.replacingOccurrences(of: "-", with: " ").capitalized, systemImage: "star.fill")
                                .font(.caption).foregroundColor(.yellow)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("已加载 Skills (\(agent.skills.count))").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 4) {
                        ForEach(agent.skills, id: \.self) { skill in
                            Label(skill, systemImage: "book.closed.fill")
                                .font(.caption)
                                .foregroundColor(.accentColor)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("擅长任务类型").font(.headline)
                    HStack(spacing: 6) {
                        ForEach(agent.preferredTaskTypes, id: \.self) { taskType in
                            Text(taskType).font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.12)).cornerRadius(6)
                        }
                    }
                }

                if !agent.digitalWorkers.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("数字工人").font(.headline)
                        ForEach(agent.digitalWorkers, id: \.self) { worker in
                            Label(worker, systemImage: "person.fill").font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            }
            .padding(20)
            .padding(.bottom, 40)
        }
    }

    private var statusColor: Color {
        switch agent.status {
        case "critical": return .red
        case "warning": return .orange
        default: return .green
        }
    }
}

struct MiniMetric: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.system(.body, design: .monospaced)).bold().foregroundColor(color).monospacedDigit()
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(8).background(Color.primary.opacity(0.04)).cornerRadius(6)
    }
}

struct EmptyOrchestra: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("🧠").font(.system(size: 48))
            Text("Agent Orchestra").font(.title3)
            Text("选择左侧 Agent 查看详情").foregroundColor(.secondary)
            Text("各 Agent 的专长、Skills、负载一目了然").font(.caption).foregroundColor(.secondary)
        }
    }
}
