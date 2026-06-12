import SwiftUI

struct PlansView: View {
    @State private var files: [PlanFile] = []
    @State private var selectedFile: PlanFile?
    @State private var document: PlanDocument?
    @State private var showNewPlanSheet = false
    @State private var newPlanName = ""

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("plans/").font(.headline)
                    Spacer()
                    Button { showNewPlanSheet = true } label: {
                        Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                    }.buttonStyle(.borderless)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)

                Divider()

                if files.isEmpty {
                    Spacer()
                    Text("暂无规划文件").foregroundColor(.secondary).font(.caption)
                    Text("~/workspace/plans/ 目录为空").foregroundColor(.secondary).font(.caption2)
                    Spacer()
                } else {
                    List(selection: $selectedFile) {
                        ForEach(files) { file in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name).font(.caption).lineLimit(1)
                                Text(file.subtitle)
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                            .padding(.vertical, 2)
                            .tag(file)
                        }
                    }
                    .listStyle(.sidebar)
                }
            }
            .frame(minWidth: 180, idealWidth: 220)

            if let document {
                PlanDocumentView(document: document, onRefresh: { reloadDocument() })
            } else {
                VStack {
                    Text("📋").font(.system(size: 48))
                    Text("选择一个规划文件").foregroundColor(.secondary)
                }
            }
        }
        .task { reloadFiles() }
        .onChange(of: selectedFile) { _, file in
            guard let file else { return }
            document = PlanService.readPlan(file)
        }
        .sheet(isPresented: $showNewPlanSheet) {
            VStack(spacing: 20) {
                Text("新建规划").font(.title3)
                TextField("任务名称", text: $newPlanName).textFieldStyle(.roundedBorder).frame(width: 300)
                HStack {
                    Button("取消") { showNewPlanSheet = false }
                    Button("创建") {
                        if let f = PlanService.createPlan(name: newPlanName) {
                            files.insert(f, at: 0)
                            selectedFile = f
                            document = PlanService.readPlan(f)
                        }
                        showNewPlanSheet = false
                        newPlanName = ""
                    }.keyboardShortcut(.defaultAction)
                }
            }.padding(30)
        }
    }

    private func reloadFiles() {
        files = PlanService.listFiles()
    }

    private func reloadDocument() {
        guard let selectedFile else { return }
        document = PlanService.readPlan(selectedFile)
    }
}

struct PlanDocumentView: View {
    let document: PlanDocument
    let onRefresh: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(document.file.name).font(.title3).bold()
                    HStack {
                        Text("进度：\(document.completedTasks)/\(document.totalTasks) 完成")
                            .font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Text("\(Int(document.progress * 100))%").font(.caption).monospacedDigit()
                    }
                    ProgressView(value: document.progress)
                }
                .padding(16)
                .background(Color.primary.opacity(0.04))
                .cornerRadius(8)

                ForEach(Array(document.phases.enumerated()), id: \.element.id) { pIdx, phase in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(phase.title).font(.headline)
                            Spacer()
                            Text(phase.progressText).font(.caption).foregroundColor(.secondary)
                        }
                        ProgressView(value: phase.progress).frame(height: 4)

                        VStack(spacing: 4) {
                            ForEach(Array(phase.tasks.enumerated()), id: \.element.id) { tIdx, task in
                                HStack(spacing: 8) {
                                    Button {
                                        PlanService.toggleTask(document: document, phaseIdx: pIdx, taskIdx: tIdx)
                                        onRefresh()
                                    } label: {
                                        Image(systemName: task.isCompleted ? "checkmark.square.fill" : "square")
                                            .foregroundColor(task.isCompleted ? .green : .secondary)
                                    }
                                    .buttonStyle(.borderless)

                                    Text(task.displayText)
                                        .font(.caption)
                                        .strikethrough(task.isCompleted)
                                        .foregroundColor(task.isCompleted ? .secondary : .primary)
                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.02))
                    .cornerRadius(6)
                }
            }
            .padding(20)
        }
    }
}
