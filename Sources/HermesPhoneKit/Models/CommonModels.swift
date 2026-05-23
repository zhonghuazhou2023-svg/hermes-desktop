import Foundation

struct KanbanDispatcherStatus: Codable, Hashable, Sendable {
    let running: Bool?
    let message: String?
}
