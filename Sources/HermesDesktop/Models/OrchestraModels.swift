import Foundation

struct AgentCapability: Codable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let ip: String
    let model: String
    let status: String
    let cpuPct: Double
    let memoryPct: Double
    let diskPct: Double
    let lastSeen: String
    let digitalWorkers: [String]
    let role: String
    let specializations: [String]
    let skills: [String]
    let capabilities: Capabilities
    let preferredTaskTypes: [String]
    let modelPreference: String
    let hasDagTask: Bool

    var roleIcon: String {
        switch role {
        case "orchestrator": return "brain.head.profile"
        case "researcher": return "magnifyingglass.circle"
        case "executor": return "hammer"
        case "hub": return "network"
        default: return "cpu"
        }
    }

    var roleLabel: String {
        switch role {
        case "orchestrator": return "🧠 主脑"
        case "researcher": return "🔬 研究员"
        case "executor": return "⚡ 执行者"
        case "hub": return "🔗 中枢"
        default: return "🛠️ 工人"
        }
    }

    var loadPct: Double { max(cpuPct, memoryPct) }

    enum CodingKeys: String, CodingKey {
        case name, ip, model, status, role, specializations, skills, capabilities
        case cpuPct = "cpu_pct"
        case memoryPct = "memory_pct"
        case diskPct = "disk_pct"
        case lastSeen = "last_seen"
        case digitalWorkers = "digital_workers"
        case preferredTaskTypes = "preferred_task_types"
        case modelPreference = "model_preference"
        case hasDagTask = "has_dag_task"
    }
}

struct Capabilities: Codable, Hashable {
    let gpu: Bool?
    let maxTokens: Int?
    let vision: Bool?

    enum CodingKeys: String, CodingKey {
        case gpu
        case maxTokens = "max_tokens"
        case vision
    }

    var summary: String {
        var parts: [String] = []
        if gpu == true { parts.append("GPU") }
        if vision == true { parts.append("👁️ 视觉") }
        if let tokens = maxTokens { parts.append("\(tokens / 1024)K") }
        return parts.isEmpty ? "基础" : parts.joined(separator: " · ")
    }
}

struct AgentListResponse: Codable {
    let agents: [AgentCapability]
}
