import SwiftUI
import AppKit

struct DAGPipelineView: View {
    @ObservedObject var store: FleetStore
    @State private var expanded = Set<String>()
    @State private var showNotes: NotesSheetItem?
    @State private var taskNotes = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "流水线 DAG")

            if store.dag.isEmpty {
                Spacer()
                Text("暂无流水线任务").foregroundColor(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(store.dag.reversed()) { task in
                            DAGRow(
                                task: task,
                                stages: DAGTask.stages,
                                stageLabels: DAGTask.stageLabels,
                                fleetReachable: store.fleetReachable,
                                expanded: expanded.contains(task.task_id),
                                onToggle: {
                                    if expanded.contains(task.task_id) { expanded.remove(task.task_id) }
                                    else { expanded.insert(task.task_id) }
                                },
                                onRetry: { Task { await store.retryTask(task.task_id) } },
                                onPause: { Task { await store.pauseTask(task.task_id) } },
                                onResume: { Task { await store.resumeTask(task.task_id) } },
                                onDelete: { Task { await store.deleteTask(task.task_id) } },
                                onSave: {
                                    showNotes = NotesSheetItem(id: task.task_id)
                                    taskNotes = ""
                                }
                            )
                        }
                    }.padding()
                }
            }
        }
        .sheet(item: $showNotes) { item in
            VStack(spacing: 12) {
                Text("保存流水线").font(.headline)
                TextEditor(text: $taskNotes)
                    .frame(height: 120)
                    .border(.secondary)
                HStack {
                    Button("取消") { showNotes = nil }
                    Button("保存") {
                        Task {
                            await store.saveTask(item.id, notes: taskNotes)
                            showNotes = nil
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(width: 400)
        }
    }
}

private struct NotesSheetItem: Identifiable {
    let id: String
}

struct DAGRow: View {
    let task: DAGTask
    let stages: [String]
    let stageLabels: [String]
    let fleetReachable: Bool
    let expanded: Bool
    let onToggle: () -> Void
    let onRetry: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onDelete: () -> Void
    let onSave: () -> Void

    @State private var copied = false
    @State private var copiedCmd = false
    @State private var stderrExpanded: Bool?
    @State private var stdoutExpanded = false

    private let mono = Font.system(.caption, design: .monospaced)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button(action: onToggle) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

                Text(task.task_id)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 56, alignment: .leading)

                Text(task.typeLabel)
                    .frame(width: 44)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12))
                    .cornerRadius(4)

                Text(task.target)
                    .lineLimit(1)
                    .frame(minWidth: 60, maxWidth: 100, alignment: .leading)

                StageIndicator(
                    stages: stages,
                    stageLabels: stageLabels,
                    currentStage: task.stage,
                    status: task.status
                )
                    .frame(minWidth: 130)

                Spacer()

                Text(task.workshop ?? "未分派")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 64, alignment: .trailing)

                TaskControlButtons(
                    task: task,
                    fleetReachable: fleetReachable,
                    onRetry: onRetry,
                    onPause: onPause,
                    onResume: onResume
                )
                Button("🗑") { onDelete() }
                    .buttonStyle(.borderless)
                    .help("删除")
                    .disabled(!fleetReachable)
                if task.status == "completed" && !task.isSaved {
                    Button("💾") { onSave() }
                        .buttonStyle(.borderless)
                        .help("保存流水线")
                }
            }

            if expanded {
                taskDetailPanel
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .cardStyle(border: task.isFailed ? .red.opacity(0.6) : task.isCompleted ? .green.opacity(0.3) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
    }

    private var taskDetailPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            timelineSection
            stageDurationSection
            if task.isFailed { failureSection }
            if task.result != nil || task.task_type == "run-command" { outputSection }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("时间轴").font(.caption).foregroundColor(.secondary)
            ForEach(Array(timelineEvents.enumerated()), id: \.offset) { idx, event in
                HStack(alignment: .top, spacing: 8) {
                    VStack(spacing: 0) {
                        Circle()
                            .fill(event.isFailed ? Color.red : Color.accentColor)
                            .frame(width: 8, height: 8)
                        if idx < timelineEvents.count - 1 {
                            Rectangle()
                                .fill(Color.gray.opacity(0.3))
                                .frame(width: 1, height: 18)
                        }
                    }
                    .frame(width: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.label).font(.caption)
                        Text(formatTime(event.time)).font(.caption2).foregroundColor(.secondary).font(mono)
                    }
                }
            }
        }
    }

    private var stageDurationSection: some View {
        Group {
            let durations = stageDurations
            if !durations.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("阶段耗时").font(.caption).foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        ForEach(Array(durations.enumerated()), id: \.offset) { _, item in
                            Text("\(item.label) \(item.duration)")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.08))
                                .cornerRadius(4)
                        }
                    }
                }
            }
        }
    }

    private var failureSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("失败详情").font(.caption).foregroundColor(.secondary)
            if let stage = failedStageLabel {
                Text("失败阶段：\(stage)").font(.caption).foregroundColor(.red)
            }
            if let err = task.result?.error ?? task.error {
                Text(err).font(.caption).foregroundColor(.red)
            }
            if let r = task.result?.retries ?? task.retries, r > 0 {
                Text("重试次数：\(r)").font(.caption2).foregroundColor(.orange)
            }
            if let steps = task.result?.output?.steps, !steps.isEmpty {
                Text("已完成步骤：\(steps.joined(separator: " → "))")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(8)
        .background(Color.red.opacity(0.06))
        .cornerRadius(6)
    }

    private var outputSection: some View {
        Group {
            if isCommandResult {
                commandResultSection
            } else {
                legacyOutputSection
            }
        }
    }

    private var isCommandResult: Bool {
        task.task_type == "run-command"
            || task.result?.output?.stdout != nil
            || task.result?.output?.stderr != nil
            || task.result?.output?.exit_code != nil
    }

    private var commandResultSection: some View {
        let status = resultStatusInfo
        let out = task.result?.output
        let stderrText = out?.stderr ?? task.result?.error ?? task.error ?? ""
        let stdoutText = out?.stdout ?? task.result?.summary ?? ""
        let cmdText = commandTextValue

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(status.emoji) \(status.label)")
                    .font(.callout.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(status.color.opacity(0.15))
            .cornerRadius(6)

            HStack(spacing: 16) {
                metaItem("退出码", value: exitCodeText)
                metaItem("耗时", value: resultDurationText)
                metaItem("重试", value: "\(task.result?.retries ?? task.retries ?? 0)")
            }
            .font(.caption)
            .foregroundColor(.secondary)

            logDisclosure(
                title: "stdout",
                text: stdoutText,
                isExpanded: Binding(
                    get: { stdoutExpanded },
                    set: { stdoutExpanded = $0 }
                ),
                tint: .secondary
            )

            logDisclosure(
                title: "stderr",
                text: stderrText,
                isExpanded: Binding(
                    get: { stderrExpanded ?? task.isFailed },
                    set: { stderrExpanded = $0 }
                ),
                tint: FleetColor.statusRed
            )

            if !cmdText.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("命令").font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Button(copiedCmd ? "已复制" : "复制") {
                            copyJSON(cmdText)
                            copiedCmd = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedCmd = false }
                        }
                        .controlSize(.mini)
                    }
                    Text(cmdText)
                        .font(mono)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.04))
                        .cornerRadius(6)
                }
            }
        }
    }

    private var legacyOutputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("产出").font(.caption).foregroundColor(.secondary)
            if let summary = task.result?.summary {
                Text(summary).font(.caption)
            }
            if let out = task.result?.output {
                HStack(spacing: 12) {
                    if let v = out.ollama_version { Label(v, systemImage: "info.circle").font(.caption2) }
                    if let m = out.model { Text(m).font(.caption2.monospaced()) }
                    if let s = out.model_size { Text(s).font(.caption2).foregroundColor(.secondary) }
                    if out.verified == true { Text("已验证").font(.caption2).foregroundColor(.green) }
                }
                if let analysis = out.analysis, !analysis.isEmpty {
                    Text(analysis)
                        .font(.caption)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.blue.opacity(0.06))
                        .cornerRadius(4)
                }
            }
            HStack {
                Text("原始 output").font(.caption2).foregroundColor(.secondary)
                Spacer()
                Button(copied ? "已复制" : "复制 JSON") {
                    copyJSON(rawOutputJSON)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                .controlSize(.mini)
            }
            ScrollView {
                Text(rawOutputJSON)
                    .font(mono)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 120)
            .padding(6)
            .background(Color.black.opacity(0.04))
            .cornerRadius(4)
        }
    }

    private struct ResultStatusInfo {
        let emoji: String
        let label: String
        let color: Color
    }

    private var resultStatusInfo: ResultStatusInfo {
        if task.isFailed {
            return .init(emoji: "🔴", label: "失败", color: FleetColor.statusRed)
        }
        if task.isCompleted {
            return .init(emoji: "🟢", label: "成功", color: FleetColor.statusGreen)
        }
        return .init(emoji: "🟡", label: "执行中", color: FleetColor.statusOrange)
    }

    private var exitCodeText: String {
        if let code = task.result?.output?.exit_code { return "\(code)" }
        if task.isFailed { return "非 0" }
        if task.isCompleted { return "0" }
        return "—"
    }

    private var resultDurationText: String {
        if let seconds = task.result?.output?.duration_seconds {
            return formatDuration(seconds)
        }
        guard let start = task.started_at.flatMap(parseISO) else { return "—" }
        let end = task.completed_at.flatMap(parseISO)
            ?? task.result?.finished_at.flatMap(parseISO)
            ?? Date()
        return formatDuration(end.timeIntervalSince(start))
    }

    private var commandTextValue: String {
        task.params?.cmd ?? task.result?.output?.cmd ?? ""
    }

    private func metaItem(_ label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text("\(label):")
            Text(value).foregroundColor(.primary).monospacedDigit()
        }
    }

    private func logDisclosure(title: String, text: String, isExpanded: Binding<Bool>, tint: Color) -> some View {
        DisclosureGroup(isExpanded: isExpanded) {
            ScrollView {
                Text(text.isEmpty ? "（空）" : text)
                    .font(mono)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 140)
            .padding(8)
            .background(tint.opacity(0.06))
            .cornerRadius(6)
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundColor(tint == .secondary ? .secondary : tint)
        }
    }

    // MARK: - Timeline helpers

    private struct TimelineEvent {
        let label: String
        let time: String
        let isFailed: Bool
    }

    private var timelineEvents: [TimelineEvent] {
        let stamps = task.timestamps ?? []
        if stamps.isEmpty {
            var events: [TimelineEvent] = []
            if let t = task.started_at {
                events.append(.init(label: "创建", time: t, isFailed: false))
            }
            if let ws = task.workshop {
                events.append(.init(label: "分派至 \(ws)", time: task.started_at ?? "", isFailed: false))
            }
            if let t = task.completed_at {
                events.append(.init(label: "完成", time: t, isFailed: false))
            }
            return events
        }
        return stamps.compactMap { ts in
            let label = timelineLabel(for: ts)
            return TimelineEvent(label: label, time: ts.time, isFailed: ts.event == "failed")
        }
    }

    private func timelineLabel(for ts: StageTimestamp) -> String {
        if ts.event == "failed" {
            let stage = DAGTask.stageLabelMap[ts.stage] ?? ts.stage
            return "失败 @ \(stage)"
        }
        if ts.event == "paused" { return "暂停" }
        if ts.event == "resumed" { return "继续" }
        if ts.event == "retry" { return "重试" }
        switch ts.stage {
        case "created": return "创建"
        case "retried": return "重新分派"
        case "dispatched":
            if let ws = ts.workshop { return "分派至 \(ws)" }
            return "分派"
        case "claimed":
            if let ws = ts.workshop { return "被 \(ws) 领取" }
            return "被领取"
        case "collect": return "开始执行（采集）"
        case "completed": return "完成"
        default:
            let name = DAGTask.stageLabelMap[ts.stage] ?? ts.stage
            return name
        }
    }

    private var stageDurations: [(label: String, duration: String)] {
        let stamps = task.timestamps ?? []
        var times: [String: Date] = [:]
        for ts in stamps where stages.contains(ts.stage) {
            if let d = parseISO(ts.time) { times[ts.stage] = d }
        }
        if let completed = task.completed_at, let d = parseISO(completed),
           let last = stages.last, times[last] == nil {
            times[last] = d
        }
        var out: [(String, String)] = []
        for (idx, stage) in stages.enumerated() {
            guard let start = times[stage] else { continue }
            let end: Date?
            if idx + 1 < stages.count, let next = times[stages[idx + 1]] {
                end = next
            } else if stage == stages.last, let c = task.completed_at.flatMap(parseISO) {
                end = c
            } else if task.isFailed, tsFailedAfter(stage) != nil {
                end = tsFailedAfter(stage)
            } else {
                continue
            }
            guard let end else { continue }
            out.append((stageLabels[idx], formatDuration(end.timeIntervalSince(start))))
        }
        return out
    }

    private func tsFailedAfter(_ stage: String) -> Date? {
        guard let stamps = task.timestamps else { return nil }
        guard let idx = stamps.firstIndex(where: { $0.stage == stage && $0.event != "failed" }) else { return nil }
        for ts in stamps[idx...] where ts.event == "failed" {
            return parseISO(ts.time)
        }
        return nil
    }

    private var failedStageLabel: String? {
        if let stamps = task.timestamps,
           let failed = stamps.last(where: { $0.event == "failed" }) {
            return DAGTask.stageLabelMap[failed.stage] ?? failed.stage
        }
        return DAGTask.stageLabelMap[task.stage] ?? task.stage_name
    }

    private var rawOutputJSON: String {
        guard let result = task.result else { return "{}" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(result),
           let s = String(data: data, encoding: .utf8) { return s }
        return "{}"
    }

    private func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    private func formatTime(_ s: String) -> String {
        guard let d = parseISO(s) else { return s }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: d)
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        if interval < 1 { return "<1s" }
        if interval < 60 { return "\(Int(interval.rounded()))s" }
        if interval < 3600 { return "\(Int(interval / 60))m \(Int(interval.truncatingRemainder(dividingBy: 60)))s" }
        return "\(Int(interval / 3600))h"
    }

    private func copyJSON(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
