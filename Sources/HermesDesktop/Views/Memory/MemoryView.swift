import SwiftUI

struct MemoryView: View {
    @State private var mode: MemoryMode = .list
    @State private var searchText = ""
    @State private var memories: [MemoryItem] = []
    @State private var selectedMemory: MemoryItem?
    @State private var editContent: String = ""
    @State private var isEditing = false
    @State private var scope: MemoryScope = .all

    enum MemoryMode {
        case list
        case graph
    }

    enum MemoryScope: String, CaseIterable {
        case all = "全部"
        case global = "全局"
        case session = "会话"

        func filter(_ items: [MemoryItem]) -> [MemoryItem] {
            switch self {
            case .all: return items
            case .global: return items.filter { $0.scope == "global" }
            case .session: return items.filter { $0.scope != "global" }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                Text("📋 列表").tag(MemoryMode.list)
                Text("🕸️ 图谱").tag(MemoryMode.graph)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 4)

            if mode == .list {
                listContent
            } else {
                GraphView()
            }
        }
    }

    private var listContent: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("搜索记忆...", text: $searchText)
                        .textFieldStyle(.plain)
                        .onSubmit { performSearch() }
                    if !searchText.isEmpty {
                        Button { searchText = ""; loadAll() } label: {
                            Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                        }.buttonStyle(.borderless)
                    }
                }
                .padding(8).background(Color.primary.opacity(0.06)).cornerRadius(8).padding(8)

                Picker("范围", selection: $scope) {
                    ForEach(MemoryScope.allCases, id: \.self) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                .pickerStyle(.segmented).padding(.horizontal, 8)

                if memories.isEmpty {
                    Spacer()
                    Text("搜索或浏览 mnemosyne 记忆").foregroundColor(.secondary).font(.caption)
                    Spacer()
                } else {
                    List(selection: $selectedMemory) {
                        ForEach(scope.filter(memories)) { mem in
                            MemoryRow(memory: mem, searchText: searchText)
                                .tag(mem)
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minWidth: 250, idealWidth: 300)
        } detail: {
            if let selectedMemory {
                MemoryDetail(memory: selectedMemory, isEditing: $isEditing, editContent: $editContent)
            } else {
                VStack {
                    Text("🧠").font(.system(size: 48))
                    Text("选择一条记忆查看详情").foregroundColor(.secondary)
                    Text("共 \(memories.count) 条记忆").font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .task { loadAll() }
        .onChange(of: searchText) { _, newValue in
            if newValue.isEmpty { loadAll() }
        }
    }

    private func performSearch() {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            loadAll()
            return
        }
        memories = MemoryItem.search(query: searchText)
    }

    private func loadAll() {
        memories = MemoryItem.all()
    }
}

struct MemoryRow: View {
    let memory: MemoryItem
    let searchText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(memory.importanceStars).font(.caption2)
                Text(memory.preview).font(.caption).lineLimit(2)
            }
            HStack {
                Text(memory.source).font(.caption2).foregroundColor(.secondary)
                Spacer()
                Text(memory.formattedTime).font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct MemoryDetail: View {
    let memory: MemoryItem
    @Binding var isEditing: Bool
    @Binding var editContent: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Label(memory.source, systemImage: "doc.text").font(.caption)
                    Label(memory.veracity, systemImage: "checkmark.shield").font(.caption)
                    Label(memory.scope, systemImage: memory.scope == "global" ? "globe" : "rectangle.stack").font(.caption)
                    Spacer()
                    if memory.importance >= 0.7 {
                        Image(systemName: "star.fill").foregroundColor(.yellow)
                    }
                }
                .foregroundColor(.secondary)
                .padding(.bottom, 8)

                if isEditing {
                    TextEditor(text: $editContent)
                        .font(.body)
                        .frame(minHeight: 200)
                        .border(Color.secondary.opacity(0.2))
                } else {
                    Text(memory.content).font(.body).textSelection(.enabled)
                }

                HStack {
                    Text("回想 \(memory.recallCount) 次")
                    Spacer()
                    Text(memory.timestamp)
                }
                .font(.caption2).foregroundColor(.secondary)
            }
            .padding(20)
        }
        .toolbar {
            ToolbarItem {
                if isEditing {
                    Button("保存") {
                        MemoryItem.update(id: memory.id, content: editContent)
                        isEditing = false
                    }
                } else {
                    Button("编辑") {
                        editContent = memory.content
                        isEditing = true
                    }
                }
            }
        }
    }
}
