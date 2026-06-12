import SwiftUI

enum TaskStatusFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case running = "进行中"
    case completed = "完成"
    case failed = "失败"

    var id: String { rawValue }

    func matches(_ status: String) -> Bool {
        switch self {
        case .all: return true
        case .running: return status == "running" || status == "pending" || status == "retrying" || status == "paused"
        case .completed: return status == "completed"
        case .failed: return status == "failed"
        }
    }
}

struct TaskDispatchView: View {
    @ObservedObject var store: FleetStore
    @State private var taskType = "analyze"
    @State private var target = ""
    @State private var commandText = ""
    @State private var workshop = ""
    @State private var dispatching = false
    @State private var statusFilter: TaskStatusFilter = .all
    @State private var expandedTaskId: String?
    @State private var showCommandTemplates = false
    @State private var commandTemplates: [CommandTemplate] = CommandTemplateStore.load()
    @State private var templateSavedHint = false

    private let types = [
        ("collect", "采集"), ("validate", "清洗"), ("analyze", "分析"),
        ("deliver", "推送"), ("install-tools", "安装工具"), ("run-command", "运行命令"),
    ]

    private var filteredTasks: [DAGTask] {
        store.dag.reversed().filter { statusFilter.matches($0.status) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "任务分派")

            ScrollView {
                VStack(alignment: .leading, spacing: FleetSpacing.md) {
                    HStack(alignment: .top, spacing: FleetSpacing.md) {
                        newTaskSection
                        WorkshopTemplateSection(store: store)
                    }

                    VStack(alignment: .leading, spacing: FleetSpacing.xs) {
                        HStack {
                            Text("任务列表").font(.subheadline).foregroundColor(.secondary)
                            Spacer()
                            Picker("状态", selection: $statusFilter) {
                                ForEach(TaskStatusFilter.allCases) { f in
                                    Text(f.rawValue).tag(f)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 100)
                        }

                        if filteredTasks.isEmpty {
                            Text("暂无任务").foregroundColor(.secondary).padding(.vertical, FleetSpacing.xs)
                        } else {
                            ForEach(filteredTasks) { t in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: FleetSpacing.xs) {
                                        Text(t.task_id)
                                            .font(Font.system(.caption, design: .monospaced))
                                        Text(t.typeLabel).font(.caption)
                                        Text(t.target)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                        Spacer()
                                        Text(t.workshop ?? "未分派")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        statusTag(t.status)
                                        TaskControlButtons(
                                            task: t,
                                            fleetReachable: store.fleetReachable,
                                            onRetry: { Task { await store.retryTask(t.task_id) } },
                                            onPause: { Task { await store.pauseTask(t.task_id) } },
                                            onResume: { Task { await store.resumeTask(t.task_id) } }
                                        )
                                        Button("📋") {
                                            expandedTaskId = expandedTaskId == t.task_id ? nil : t.task_id
                                        }
                                        .buttonStyle(.borderless)
                                        .help("详情")
                                    }
                                    if expandedTaskId == t.task_id {
                                        taskBriefDetail(t)
                                    }
                                }
                                .padding(.vertical, FleetSpacing.xs / 2)
                                Divider()
                            }
                        }
                    }
                    .cardStyle()
                }
                .padding(FleetSpacing.md)
            }
        }
    }

    private var newTaskSection: some View {
        VStack(alignment: .leading, spacing: FleetSpacing.sm) {
            Text("新建任务").font(.subheadline).foregroundColor(.secondary)

            HStack(alignment: .firstTextBaseline) {
                Picker("类型", selection: $taskType) {
                    ForEach(types, id: \.0) { t in
                        Text(t.1).tag(t.0)
                    }
                }
                if taskType == "run-command" {
                    Button("📋 模板") { showCommandTemplates = true }
                        .popover(isPresented: $showCommandTemplates) {
                            commandTemplatePicker
                        }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Picker("车间", selection: $workshop) {
                Text("自动分派").tag("")
                ForEach(store.deployableWorkshops) { ws in
                    Text(ws.name).tag(ws.name)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if taskType == "run-command" {
                TextField("命令", text: $commandText)
                    .textFieldStyle(.roundedBorder)
                    .font(Font.system(.caption, design: .monospaced))
                HStack {
                    Text("保存为模板")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    if templateSavedHint {
                        Text("已保存").font(.caption2).foregroundColor(FleetColor.statusGreen)
                    }
                    Button("💾 保存") { saveCommandTemplate() }
                        .disabled(commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  && target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            TextField("目标名称", text: $target)
                .textFieldStyle(.roundedBorder)

            Button(dispatching ? "分派中..." : "分派 →") {
                dispatching = true
                Task {
                    var params: [String: Any] = [:]
                    if taskType == "run-command" {
                        params["cmd"] = commandText
                        params["timeout"] = 1200
                    }
                    await store.dispatchTask(
                        type: taskType,
                        target: target.isEmpty ? "未指定" : target,
                        workshop: workshop.isEmpty ? nil : workshop,
                        params: params.isEmpty ? nil : params
                    )
                    target = ""
                    commandText = ""
                    dispatching = false
                }
            }
            .disabled(dispatching || !store.fleetReachable)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func statusTag(_ status: String) -> some View {
        let label: String
        let color: Color
        switch status {
        case "completed": label = "完成"; color = FleetColor.statusGreen
        case "running": label = "进行中"; color = .blue
        case "pending": label = "等待"; color = .gray
        case "retrying": label = "重试"; color = FleetColor.statusOrange
        case "paused": label = "暂停"; color = .yellow
        case "failed": label = "失败"; color = FleetColor.statusRed
        default: label = status; color = .secondary
        }
        return Text(label)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(4)
    }

    private func taskBriefDetail(_ task: DAGTask) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text("阶段：\(task.stage_name ?? task.stage)").font(.caption2)
                Text("状态：\(task.status)").font(.caption2)
                if let r = task.retries, r > 0 {
                    Text("重试 \(r) 次").font(.caption2).foregroundColor(.orange)
                }
            }
            if let err = task.error ?? task.result?.error {
                Text(err).font(.caption2).foregroundColor(.red).lineLimit(3)
            } else if let summary = task.result?.summary {
                Text(summary).font(.caption2).foregroundColor(.secondary).lineLimit(2)
            }
        }
        .padding(8)
        .background(FleetColor.card)
        .cornerRadius(6)
    }

    private var commandTemplatePicker: some View {
        VStack(alignment: .leading, spacing: FleetSpacing.sm) {
            Text("命令模板").font(.headline)
            if commandTemplates.isEmpty {
                Text("暂无模板").foregroundColor(.secondary).padding(.vertical, FleetSpacing.xs)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(commandTemplates) { item in
                            Button {
                                commandText = item.command
                                target = item.target
                                showCommandTemplates = false
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.target.isEmpty ? "未命名目标" : item.target)
                                        .font(.callout)
                                    Text(item.command)
                                        .font(Font.system(.caption, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
        }
        .padding(FleetSpacing.sm)
        .frame(width: 360)
    }

    private func saveCommandTemplate() {
        let cmd = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty || !name.isEmpty else { return }
        commandTemplates = CommandTemplateStore.add(target: name, command: cmd, to: commandTemplates)
        templateSavedHint = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { templateSavedHint = false }
    }
}

struct CommandTemplate: Codable, Identifiable {
    let id: UUID
    let target: String
    let command: String
    let savedAt: Date

    init(id: UUID = UUID(), target: String, command: String, savedAt: Date = Date()) {
        self.id = id
        self.target = target
        self.command = command
        self.savedAt = savedAt
    }
}

enum CommandTemplateStore {
    static let key = "hf.runCommandTemplates"

    static func load() -> [CommandTemplate] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([CommandTemplate].self, from: data) else {
            return []
        }
        return items
    }

    static func save(_ items: [CommandTemplate]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func add(target: String, command: String, to existing: [CommandTemplate]) -> [CommandTemplate] {
        var items = existing.filter { !($0.target == target && $0.command == command) }
        items.insert(CommandTemplate(target: target, command: command), at: 0)
        save(Array(items.prefix(20)))
        return Array(items.prefix(20))
    }
}

struct WorkshopTemplateSection: View {
    @ObservedObject var store: FleetStore
    @State private var role: WorkshopRole = .manager
    @State private var targetWorkshop = ""
    @State private var skillContent = ""
    @State private var deploying = false
    @State private var deployMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: FleetSpacing.sm) {
            Text("车间模板").font(.subheadline).foregroundColor(.secondary)

            Picker("角色", selection: $role) {
                ForEach(WorkshopRole.allCases) { r in
                    Text(r.rawValue).tag(r)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if store.deployableWorkshops.isEmpty {
                Text("无可部署车间（需已部署车间主任）").foregroundColor(.secondary)
            } else {
                Picker("目标战舰", selection: $targetWorkshop) {
                    ForEach(store.deployableWorkshops) { ws in
                        Text(ws.name).tag(ws.name)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("内容预览").font(.caption).foregroundColor(.secondary)
            TextEditor(text: $skillContent)
                .font(Font.system(.caption, design: .monospaced))
                .frame(minHeight: 140)
                .overlay(
                    RoundedRectangle(cornerRadius: FleetColor.cardRadius)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )

            HStack {
                Button(deploying ? "下发中..." : "下发") {
                    deploying = true
                    deployMessage = nil
                    Task {
                        deployMessage = await store.deploySkill(
                            workshop: targetWorkshop,
                            role: role.rawValue,
                            content: skillContent
                        )
                        deploying = false
                    }
                }
                .disabled(deploying || targetWorkshop.isEmpty || skillContent.isEmpty || !store.fleetReachable)

                if let deployMessage {
                    Text(deployMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .onAppear { refreshTemplate() }
        .onChange(of: role) { _, _ in refreshTemplate() }
        .onChange(of: targetWorkshop) { _, _ in refreshTemplate() }
        .onChange(of: store.deployableWorkshops.count) { _, _ in
            syncWorkshop()
            if skillContent.isEmpty { refreshTemplate() }
        }
    }

    private func syncWorkshop() {
        if targetWorkshop.isEmpty || !store.deployableWorkshops.contains(where: { $0.name == targetWorkshop }) {
            targetWorkshop = store.deployableWorkshops.first?.name ?? ""
        }
    }

    private func refreshTemplate() {
        syncWorkshop()
        guard !targetWorkshop.isEmpty else { return }
        skillContent = role.template(workshop: targetWorkshop)
    }
}
