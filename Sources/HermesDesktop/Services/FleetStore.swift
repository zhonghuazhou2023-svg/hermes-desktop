import SwiftUI

@MainActor
final class FleetStore: ObservableObject {
    @Published var workshops: [WS] = []
    @Published var dag: [DAGTask] = []
    @Published var config = AppConfig(default_model: "deepseek-v4-pro", workshop_models: [:])
    @Published var fleetReachable = false
    @Published var gpuOnline = false
    @Published var gpuTunnelActive = false
    @Published var gpuLocalUrl = "—"
    @Published var systemStatus: SystemStatus?
    @Published var errorMessage: String?
    @Published var deepseekDailyTokens = "—"
    @Published var sessionCount = 0

    private var dwFailStreak: [String: Int] = [:]
    private var dwHistory: [String: [DWRunState]] = [:]

    var deployableWorkshops: [WS] {
        workshops.filter(\.isDeployable)
    }

    func failStreak(workshop: String, dw name: String) -> Int {
        dwFailStreak["\(workshop):\(name)"] ?? 0
    }

    func dwHistory(for workshop: String, dw name: String) -> [DWRunState] {
        dwHistory["\(workshop):\(name)"] ?? []
    }

    func loadStatus() async {
        do {
            let raw: StatusResponse = try await FleetAPIClient.get("/api/status")
            let loaded = raw.workshops.map { name, m in
                WS.from(name: name, metrics: m, fallbackModel: raw.config.default_model)
            }.sorted { $0.name < $1.name }
            updateFailStreaks(from: loaded)
            workshops = loaded
            dag = raw.dag
            config = raw.config
            fleetReachable = true
            errorMessage = nil
            await loadGPUStatus()
            await loadSystemStatus()
            await loadUsage()
        } catch {
            fleetReachable = false
            errorMessage = "无法连接 factory (:8788)"
            workshops = []
            dag = []
        }
    }

    func loadGPUStatus() async {
        do {
            let g: GpuStatus = try await FleetAPIClient.get("/api/gpu/status")
            gpuOnline = g.ssh_online ?? false
            gpuTunnelActive = g.tunnel_active ?? false
            gpuLocalUrl = g.local_url ?? "—"
        } catch {
            gpuOnline = false
        }
    }

    func loadSystemStatus() async {
        do { systemStatus = try await FleetAPIClient.get("/api/system") }
        catch { systemStatus = nil }
    }

    func loadUsage() async {
        guard fleetReachable else { return }
        guard let stats: UsageStats = try? await FleetAPIClient.get("/api/usage") else { return }
        let input = stats.input_tokens ?? 0
        let output = stats.output_tokens ?? 0
        let total = input + output
        if total >= 1_000_000 {
            deepseekDailyTokens = String(format: "%.1fM", Double(total) / 1_000_000)
        } else if total >= 1_000 {
            deepseekDailyTokens = String(format: "%.1fk", Double(total) / 1_000)
        } else {
            deepseekDailyTokens = "\(total)"
        }
        sessionCount = stats.sessions ?? 0
    }

    func loadRepoFiles(workshop: String) async -> [RepoFile] {
        guard let resp: WorkshopFilesResponse = try? await FleetAPIClient.get("/api/workshops/\(workshop)/files") else {
            return []
        }
        return resp.files
    }

    func dispatchTask(type: String, target: String, workshop: String? = nil, params: [String: Any]? = nil) async {
        var body: [String: Any] = ["type": type, "target": target]
        if let workshop, !workshop.isEmpty { body["workshop"] = workshop }
        if let params, !params.isEmpty { body["params"] = params }
        _ = try? await FleetAPIClient.post("/api/tasks", body: body)
        await loadStatus()
    }

    func retryTask(_ taskId: String) async { _ = try? await FleetAPIClient.post("/api/tasks/\(taskId)/retry", body: [:]); await loadStatus() }
    func pauseTask(_ taskId: String) async { _ = try? await FleetAPIClient.post("/api/tasks/\(taskId)/pause", body: [:]); await loadStatus() }
    func resumeTask(_ taskId: String) async { _ = try? await FleetAPIClient.post("/api/tasks/\(taskId)/resume", body: [:]); await loadStatus() }
    func deleteTask(_ taskId: String) async { _ = try? await FleetAPIClient.post("/api/tasks/\(taskId)/delete", body: [:]); await loadStatus() }
    func saveTask(_ taskId: String, notes: String) async {
        _ = try? await FleetAPIClient.post("/api/tasks/\(taskId)/save", body: ["notes": notes])
        await loadStatus()
    }

    func deploySkill(workshop: String, role: String, content: String) async -> String {
        let body: [String: Any] = ["workshop": workshop, "role": role, "content": content]
        if let resp: SkillDeployResponse = try? await FleetAPIClient.post("/api/skills/deploy", body: body) {
            if resp.ok == true { return "已下发 → \(resp.path ?? workshop)" }
            return resp.error ?? "下发失败"
        }
        return "下发失败：API 无响应"
    }

    func connectGPU() async {
        let (code, _) = (try? await FleetAPIClient.post("/api/gpu/connect", body: [:])) ?? (0, Data())
        if code == 200 { gpuTunnelActive = true; gpuLocalUrl = "http://localhost:18000" }
        await loadGPUStatus()
    }

    func disconnectGPU() async {
        let (code, _) = (try? await FleetAPIClient.post("/api/gpu/disconnect", body: [:])) ?? (0, Data())
        if code == 200 { gpuTunnelActive = false; gpuLocalUrl = "—" }
        await loadGPUStatus()
    }

    private func updateFailStreaks(from loaded: [WS]) {
        var nextStreak = dwFailStreak
        var nextHistory = dwHistory
        for ws in loaded {
            for dw in ws.digital_workers {
                let key = "\(ws.name):\(dw.name)"
                let state = DWRunState.from(dw)
                if state == .running {
                    nextStreak[key] = 0
                } else {
                    nextStreak[key] = (nextStreak[key] ?? 0) + 1
                }
                var hist = nextHistory[key] ?? []
                if hist.last != state {
                    hist.append(state)
                    if hist.count > 10 { hist.removeFirst() }
                }
                nextHistory[key] = hist
            }
        }
        dwFailStreak = nextStreak
        dwHistory = nextHistory
    }
}

private struct EmptyResponse: Decodable {}
