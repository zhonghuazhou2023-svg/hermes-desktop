import SwiftUI

struct WorkshopOverviewView: View {
    @ObservedObject var store: FleetStore
    @State private var expanded = Set<String>()

    private var onlineCount: Int { store.workshops.count }
    private var abnormalCount: Int { store.workshops.filter(\.isAbnormal).count }
    private var activeDW: Int { store.workshops.reduce(0) { $0 + $1.digital_workers.count } }
    private var avgCPU: Int {
        guard !store.workshops.isEmpty else { return 0 }
        return Int(store.workshops.reduce(0.0) { $0 + $1.cpu } / Double(store.workshops.count))
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "车间总览")

            if store.workshops.isEmpty {
                Spacer()
                Text("等待车间上报...")
                    .font(.body)
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: FleetSpacing.sm) {
                        statsRow
                        ForEach(store.workshops) { w in
                            WorkshopRow(
                                w: w,
                                store: store,
                                expanded: expanded.contains(w.name),
                                onToggle: {
                                    if expanded.contains(w.name) { expanded.remove(w.name) }
                                    else { expanded.insert(w.name) }
                                }
                            )
                        }
                    }
                    .padding(FleetSpacing.md)
                }
            }
        }
        .background(FleetColor.content)
    }

    private var statsRow: some View {
        HStack(spacing: FleetSpacing.sm) {
            StatCard(label: "在线数", value: "\(onlineCount)", color: FleetColor.statusGreen)
            StatCard(label: "异常数", value: "\(abnormalCount)", color: abnormalCount > 0 ? FleetColor.statusOrange : FleetColor.statusGreen)
            StatCard(label: "活跃DW", value: "\(activeDW)", color: .accentColor)
            StatCard(label: "平均CPU", value: "\(avgCPU)%", color: avgCPU > 75 ? FleetColor.statusOrange : FleetColor.statusGreen)
        }
    }
}

struct WorkshopRow: View {
    let w: WS
    @ObservedObject var store: FleetStore
    let expanded: Bool
    let onToggle: () -> Void

    @State private var repoFiles: [RepoFile] = []
    @State private var loadingFiles = false
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            collapsedRow
                .padding(.horizontal, FleetSpacing.sm)
                .padding(.vertical, FleetSpacing.xs)

            if expanded {
                expandedContent
                    .padding(.horizontal, FleetSpacing.sm)
                    .padding(.bottom, FleetSpacing.sm)
            }
        }
        .background(cardBackground)
        .cornerRadius(FleetColor.cardRadius)
        .onHover { isHovered = $0 }
        .task(id: expanded) {
            guard expanded, w.name == "kandelin" else { return }
            loadingFiles = true
            repoFiles = await store.loadRepoFiles(workshop: "kandelin")
            loadingFiles = false
        }
    }

    private var cardBackground: Color {
        if expanded { return FleetColor.sidebarSelected }
        if isHovered { return FleetColor.rowHover }
        return FleetColor.cardFill
    }

    private var collapsedRow: some View {
        HStack(spacing: WorkshopRowLayout.spacing) {
            Button(action: onToggle) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: WorkshopRowLayout.chevronWidth)
            }
            .buttonStyle(.plain)

            Button(action: onToggle) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(w.name)
                        .font(.body.weight(.medium))
                        .foregroundColor(.accentColor)
                    NodeRoleBadge(role: w.nodeRole)
                }
                .frame(width: WorkshopRowLayout.nameWidth, alignment: .leading)
            }
            .buttonStyle(.plain)

            StatusDot(status: w.status)
                .frame(width: WorkshopRowLayout.statusWidth)

            HStack(spacing: WorkshopRowLayout.metricSpacing) {
                CompactMetricCell(label: "CPU", value: w.cpu, color: .blue)
                    .frame(width: WorkshopRowLayout.metricColumnWidth)
                CompactMetricCell(label: "内存", value: w.memory, color: .purple)
                    .frame(width: WorkshopRowLayout.metricColumnWidth)
                CompactMetricCell(label: "磁盘", value: w.disk, color: .orange)
                    .frame(width: WorkshopRowLayout.metricColumnWidth)
            }
            .frame(width: WorkshopRowLayout.metricsTotalWidth)

            HStack(spacing: 4) {
                DWCapsule(count: w.digital_workers.count)
                DWHealthTrend(workers: w.digital_workers, store: store, workshop: w.name)
            }
            .frame(width: WorkshopRowLayout.dwWidth, alignment: .center)

            Text(w.model)
                .font(Font.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(minWidth: WorkshopRowLayout.modelMinWidth, maxWidth: WorkshopRowLayout.modelMaxWidth, alignment: .trailing)

            Text(w.ip)
                .font(Font.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: WorkshopRowLayout.ipWidth, alignment: .trailing)

            Spacer(minLength: 0)
        }
        .frame(minHeight: 52)
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: FleetSpacing.sm) {
            VStack(spacing: FleetSpacing.xs) {
                MetricBar(label: "CPU", value: w.cpu)
                MetricBar(label: "内存", value: w.memory)
                MetricBar(label: "磁盘", value: w.disk)
            }

            HStack {
                Text("上次上报")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(formatTime(w.last_seen))
                    .font(Font.system(.caption, design: .monospaced))
            }

            if w.isAbnormal, let diag = w.ai_diag, diag.diag != nil {
                VStack(alignment: .leading, spacing: FleetSpacing.xs / 2) {
                    if let d = diag.diag {
                        Label(d, systemImage: "stethoscope").font(.caption)
                    }
                    if let a = diag.action {
                        Label(a, systemImage: "lightbulb").font(.caption).foregroundColor(.secondary)
                    }
                }
                .padding(FleetSpacing.xs)
                .background(FleetColor.statusRed.opacity(0.08))
                .cornerRadius(FleetColor.cardRadius)
            }

            digitalWorkerSection

            if w.name == "kandelin" {
                RepoFilesTable(files: repoFiles, loading: loadingFiles)
            }
        }
    }

    private var digitalWorkerSection: some View {
        VStack(alignment: .leading, spacing: FleetSpacing.xs) {
            Text("数字员工").font(.caption).foregroundColor(.secondary)
            if w.digital_workers.isEmpty {
                Text("暂无").font(.caption2).foregroundColor(.secondary)
            } else {
                ForEach(w.digital_workers) { dw in
                    DWStatusBadge(
                        dw: dw,
                        failStreak: store.failStreak(workshop: w.name, dw: dw.name)
                    )
                }
            }
        }
    }

    private func formatTime(_ iso: String) -> String {
        guard !iso.isEmpty else { return "-" }
        if iso.contains("T") {
            let parts = iso.split(separator: "T", maxSplits: 1)
            if parts.count == 2 {
                let date = parts[0].replacingOccurrences(of: "-", with: "/")
                let time = String(parts[1].prefix(5))
                return "\(date) \(time)"
            }
        }
        return iso
    }
}

enum RepoFileSortKey: String, CaseIterable {
    case name, size, date

    var label: String {
        switch self {
        case .name: return "名称"
        case .size: return "大小"
        case .date: return "日期"
        }
    }
}

struct RepoFilesTable: View {
    let files: [RepoFile]
    let loading: Bool
    @State private var searchText = ""
    @State private var sortKey: RepoFileSortKey = .name
    @State private var sortAsc = true

    private var filtered: [RepoFile] {
        var list = files
        if !searchText.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        list.sort { a, b in
            let cmp: Bool
            switch sortKey {
            case .name:
                cmp = a.name.localizedCompare(b.name) == .orderedAscending
            case .size:
                cmp = (a.size ?? 0) < (b.size ?? 0)
            case .date:
                cmp = (a.modified ?? "") < (b.modified ?? "")
            }
            return sortAsc ? cmp : !cmp
        }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FleetSpacing.xs) {
            HStack {
                Text("仓库文件").font(.caption).foregroundColor(.secondary)
                Spacer()
                if loading { ProgressView().controlSize(.mini) }
            }

            TextField("搜索文件...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .font(.caption)

            if filtered.isEmpty && !loading {
                Text("暂无文件").font(.caption2).foregroundColor(.secondary)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: FleetSpacing.xs) {
                        sortHeader("名称", key: .name)
                        sortHeader("大小", key: .size, width: 72)
                        sortHeader("日期", key: .date, width: 110)
                    }
                    .padding(.vertical, FleetSpacing.xs / 2)
                    .background(Color.primary.opacity(0.03))

                    ForEach(filtered) { f in
                        HStack(spacing: FleetSpacing.xs) {
                            Text(f.name)
                                .font(Font.system(.caption2, design: .monospaced))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(FileSizeFormat.display(f))
                                .font(Font.system(.caption2, design: .monospaced))
                                .monospacedDigit()
                                .foregroundColor(.secondary)
                                .frame(width: 72, alignment: .trailing)
                            Text(f.modified ?? "-")
                                .font(Font.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 110, alignment: .trailing)
                        }
                        .padding(.vertical, 3)
                        Divider()
                    }
                }
            }
        }
        .padding(FleetSpacing.xs)
        .background(FleetColor.statusOrange.opacity(0.06))
        .cornerRadius(FleetColor.cardRadius)
    }

    private func sortHeader(_ title: String, key: RepoFileSortKey, width: CGFloat? = nil) -> some View {
        Button {
            if sortKey == key { sortAsc.toggle() } else { sortKey = key; sortAsc = true }
        } label: {
            HStack(spacing: 2) {
                Text(title).font(.caption2).foregroundColor(.secondary)
                if sortKey == key {
                    Image(systemName: sortAsc ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: width == nil ? .infinity : width, alignment: width == nil ? .leading : .trailing)
        }
        .buttonStyle(.plain)
    }
}
