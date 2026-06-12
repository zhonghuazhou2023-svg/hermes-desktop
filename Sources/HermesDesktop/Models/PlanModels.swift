import Foundation

struct PlanFile: Identifiable, Equatable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let modified: Date
    let size: Int

    var formattedSize: String {
        if size < 1024 { return "\(size) B" }
        return String(format: "%.1f KB", Double(size) / 1024)
    }

    var modifiedLabel: String {
        modified.formatted(date: .abbreviated, time: .shortened)
    }

    var subtitle: String {
        "\(formattedSize) · \(modifiedLabel)"
    }
}

struct PlanTask: Identifiable, Equatable {
    let id = UUID()
    let text: String
    var isCompleted: Bool
    let lineNumber: Int
    let indentLevel: Int

    var displayText: String {
        text.replacingOccurrences(of: "- [x] ", with: "")
            .replacingOccurrences(of: "- [ ] ", with: "")
            .replacingOccurrences(of: "- [X] ", with: "")
    }
}

struct PlanPhase: Identifiable {
    let id = UUID()
    let title: String
    let lineNumber: Int
    var tasks: [PlanTask]

    var completedCount: Int { tasks.filter(\.isCompleted).count }
    var progress: Double { tasks.isEmpty ? 0 : Double(completedCount) / Double(tasks.count) }
    var progressText: String { "\(completedCount)/\(tasks.count)" }
}

struct PlanDocument: Identifiable {
    let id = UUID()
    let file: PlanFile
    var phases: [PlanPhase]
    var content: String

    var totalTasks: Int { phases.reduce(0) { $0 + $1.tasks.count } }
    var completedTasks: Int { phases.reduce(0) { $0 + $1.completedCount } }
    var progress: Double { totalTasks == 0 ? 0 : Double(completedTasks) / Double(totalTasks) }
}
