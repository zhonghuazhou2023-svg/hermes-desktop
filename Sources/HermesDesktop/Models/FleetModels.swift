import Foundation
import SwiftUI

struct AIDiag: Codable {
    let severity: String?
    let diag: String?
    let action: String?
}

struct DigitalWorker: Codable, Identifiable {
    var id: String { name }
    let name: String
    let status: String?
    let last_run: String?
    let alerts: [String]?
}

struct WorkshopHealth: Codable {
    let dw: String?
    let timestamp: String?
    let status: String?
}

enum WorkshopNodeRole: String {
    case managerDeployed = "已部署车间主任"
    case heartbeatOnly = "仅心跳上报"
    case offline = "离线"

    var color: Color {
        switch self {
        case .managerDeployed: return .green
        case .heartbeatOnly: return .orange
        case .offline: return .red
        }
    }

    static func detect(lastSeen: String, digitalWorkers: [DigitalWorker], hasHealth: Bool) -> WorkshopNodeRole {
        guard let age = ISO8601Helper.ageSeconds(lastSeen), age <= 600 else { return .offline }
        if !digitalWorkers.isEmpty || hasHealth { return .managerDeployed }
        return .heartbeatOnly
    }
}

enum DWRunState: String, Equatable {
    case running = "运行中"
    case timeout = "巡检超时"
    case disconnected = "失联"

    var color: Color {
        switch self {
        case .running: return FleetColor.statusGreen
        case .timeout: return FleetColor.statusOrange
        case .disconnected: return FleetColor.statusRed
        }
    }

    static func from(_ dw: DigitalWorker) -> DWRunState {
        guard let last = dw.last_run, let age = ISO8601Helper.ageSeconds(last) else {
            return .disconnected
        }
        if age > 3600 { return .disconnected }
        if age > 1800 { return .timeout }
        if dw.status == "alert" { return .timeout }
        return .running
    }
}

enum ISO8601Helper {
    static func parse(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        if let d = iso.date(from: s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: s)
    }

    static func ageSeconds(_ s: String) -> Int? {
        guard let d = parse(s) else { return nil }
        return max(0, Int(Date().timeIntervalSince(d)))
    }
}

struct RepoFile: Codable, Identifiable {
    var id: String { path ?? name }
    let name: String
    let path: String?
    let size: Int?
    let size_human: String?
    let modified: String?
}

struct WorkshopFilesResponse: Decodable {
    let workshop: String
    let files: [RepoFile]
}

struct WSMetrics: Codable {
    let cpu: Double
    let memory: Double
    let disk: Double
    let last_seen: String
    let status: String
    let ai_diag: AIDiag?
    let model: String?
    let digital_workers: [DigitalWorker]?
    let ip: String?
    let health: WorkshopHealth?
}

struct WS: Identifiable {
    var id: String { name }
    let name: String
    let cpu, memory, disk: Double
    let last_seen: String
    let status: String
    let ai_diag: AIDiag?
    let model: String
    let digital_workers: [DigitalWorker]
    let ip: String
    let hasHealth: Bool

    var isAbnormal: Bool { status == "critical" || status == "warning" }
    var isDeployable: Bool { nodeRole == .managerDeployed }
    var nodeRole: WorkshopNodeRole {
        WorkshopNodeRole.detect(lastSeen: last_seen, digitalWorkers: digital_workers, hasHealth: hasHealth)
    }

    static func from(name: String, metrics: WSMetrics, fallbackModel: String) -> WS {
        WS(
            name: name, cpu: metrics.cpu, memory: metrics.memory, disk: metrics.disk,
            last_seen: metrics.last_seen, status: metrics.status, ai_diag: metrics.ai_diag,
            model: metrics.model ?? fallbackModel,
            digital_workers: metrics.digital_workers ?? [], ip: metrics.ip ?? "-",
            hasHealth: metrics.health != nil
        )
    }
}

struct TaskParams: Codable {
    let cmd: String?
    let timeout: Int?
}

struct TaskOutput: Codable {
    let stdout: String?
    let stderr: String?
    let exit_code: Int?
    let cmd: String?
    let ollama_version: String?
    let model: String?
    let model_size: String?
    let verified: Bool?
    let steps: [String]?
    let error: String?
    let analysis: String?
    let duration_seconds: Double?
}

struct TaskReport: Codable {
    let status: String?
    let summary: String?
    let error: String?
    let retries: Int?
    let output: TaskOutput?
    let finished_at: String?
}

struct StageTimestamp: Codable {
    let stage: String
    let time: String
    let workshop: String?
    let event: String?
}

struct DAGTask: Codable, Identifiable {
    var id: String { task_id }
    let task_id: String
    let task_type: String
    let target: String
    let stage: String
    let stage_name: String?
    let status: String
    let workshop: String?
    let started_at: String?
    let completed_at: String?
    let error: String?
    let retries: Int?
    let result: TaskReport?
    let timestamps: [StageTimestamp]?
    let params: TaskParams?
    let notes: String?
    let saved: Bool?

    var typeLabel: String { Self.typeNames[task_type] ?? task_type }
    var isFailed: Bool { status == "failed" || status == "retrying" }
    var isCompleted: Bool { status == "completed" }
    var isSaved: Bool { saved == true }

    static let typeNames: [String: String] = [
        "collect": "采集", "validate": "清洗", "analyze": "分析", "deliver": "推送",
        "install-tools": "装工具", "run-command": "运行命令",
    ]
    static let stages = ["collect", "validate", "analyze", "deliver"]
    static let stageLabels = ["采集", "清洗", "分析", "推送"]
    static let stageLabelMap = Dictionary(uniqueKeysWithValues: zip(stages, stageLabels))
}

struct AppConfig: Codable {
    var default_model: String
    var workshop_models: [String: String]
}

struct StatusResponse: Codable {
    let workshops: [String: WSMetrics]
    let dag: [DAGTask]
    let config: AppConfig
}

struct GpuStatus: Codable {
    let tunnel_active: Bool?
    let ssh_online: Bool?
    let local_url: String?
}

struct UsageStats: Codable {
    let input_tokens: Int?
    let output_tokens: Int?
    let sessions: Int?
    let estimated_cost_usd: Double?
}

struct SystemStatus: Codable {
    let pid: Int
    let uptime_seconds: Int
}

struct SkillDeployResponse: Decodable {
    let ok: Bool?
    let path: String?
    let error: String?
}
