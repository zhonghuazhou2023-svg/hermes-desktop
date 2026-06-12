import Foundation

enum OrchestraService {
    static func loadAgents() async -> [AgentCapability] {
        do {
            let resp: AgentListResponse = try await FleetAPIClient.get("/api/agents")
            return resp.agents
        } catch {
            return []
        }
    }
}
