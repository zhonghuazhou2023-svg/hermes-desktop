import Foundation

enum PlanService {
    static let plansDir: String = {
        let workspacePlans = NSHomeDirectory() + "/workspace/plans"
        if !FileManager.default.fileExists(atPath: workspacePlans) {
            try? FileManager.default.createDirectory(atPath: workspacePlans, withIntermediateDirectories: true)
        }
        return workspacePlans
    }()

    static func listFiles() -> [PlanFile] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: plansDir) else { return [] }
        return files
            .filter { $0.hasSuffix(".md") }
            .compactMap { name -> PlanFile? in
                let fullPath = plansDir + "/" + name
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath),
                      let modified = attrs[.modificationDate] as? Date,
                      let size = attrs[.size] as? Int else { return nil }
                return PlanFile(name: name, path: fullPath, modified: modified, size: size)
            }
            .sorted { $0.modified > $1.modified }
    }

    static func readPlan(_ file: PlanFile) -> PlanDocument? {
        guard let content = try? String(contentsOfFile: file.path, encoding: .utf8) else { return nil }
        return parsePlanDocument(file: file, content: content)
    }

    static func parsePlanDocument(file: PlanFile, content: String) -> PlanDocument {
        let lines = content.components(separatedBy: "\n")
        var phases: [PlanPhase] = []
        var currentPhaseTitle = "任务"
        var currentTasks: [PlanTask] = []
        var currentPhaseLine = 0

        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") || trimmed.hasPrefix("### ") {
                if !currentTasks.isEmpty {
                    phases.append(PlanPhase(
                        title: currentPhaseTitle,
                        lineNumber: currentPhaseLine,
                        tasks: currentTasks
                    ))
                }
                currentPhaseTitle = trimmed
                    .replacingOccurrences(of: "## ", with: "")
                    .replacingOccurrences(of: "### ", with: "")
                currentTasks = []
                currentPhaseLine = i
            } else if trimmed.hasPrefix("- [x]") || trimmed.hasPrefix("- [X]") {
                let indent = line.prefix(while: { $0 == " " }).count
                currentTasks.append(PlanTask(text: trimmed, isCompleted: true, lineNumber: i, indentLevel: indent))
            } else if trimmed.hasPrefix("- [ ]") {
                let indent = line.prefix(while: { $0 == " " }).count
                currentTasks.append(PlanTask(text: trimmed, isCompleted: false, lineNumber: i, indentLevel: indent))
            }
        }
        if !currentTasks.isEmpty {
            phases.append(PlanPhase(title: currentPhaseTitle, lineNumber: currentPhaseLine, tasks: currentTasks))
        }
        if phases.isEmpty {
            phases.append(PlanPhase(title: "全部任务", lineNumber: 0, tasks: currentTasks))
        }
        return PlanDocument(file: file, phases: phases, content: content)
    }

    static func toggleTask(document: PlanDocument, phaseIdx: Int, taskIdx: Int) {
        let task = document.phases[phaseIdx].tasks[taskIdx]
        let oldLine = task.isCompleted ? "- [x] " : "- [ ] "
        let newLine = task.isCompleted ? "- [ ] " : "- [x] "

        guard var content = try? String(contentsOfFile: document.file.path, encoding: .utf8) else { return }
        var lines = content.components(separatedBy: "\n")
        guard task.lineNumber < lines.count else { return }

        var line = lines[task.lineNumber]
        line = line.replacingOccurrences(of: oldLine, with: newLine)
            .replacingOccurrences(of: "- [X] ", with: "- [ ] ")
        lines[task.lineNumber] = line

        content = lines.joined(separator: "\n")
        try? content.write(toFile: document.file.path, atomically: true, encoding: .utf8)
    }

    static func createPlan(name: String) -> PlanFile? {
        let safeName = name.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
            .appending(".md")
        let path = plansDir + "/task_plan_" + safeName
        let template = """
        # \(name)

        > 状态: 进行中

        ## Phase 1

        - [ ] 第一步
        - [ ] 第二步

        ---
        创建于 \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short))
        """
        try? template.write(toFile: path, atomically: true, encoding: .utf8)
        return PlanFile(name: safeName, path: path, modified: Date(), size: template.utf8.count)
    }
}
