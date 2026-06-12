import Foundation

struct MemoryItem: Identifiable, Equatable, Hashable {
    let id: String
    let content: String
    let source: String
    let timestamp: String
    let importance: Double
    let veracity: String
    let scope: String
    let recallCount: Int
    let lastRecalled: String
    let sessionId: String

    var importanceStars: String {
        if importance >= 0.9 { return "⭐⭐⭐" }
        if importance >= 0.7 { return "⭐⭐" }
        if importance >= 0.5 { return "⭐" }
        return ""
    }

    var formattedTime: String {
        ISO8601DateFormatter().date(from: timestamp)
            .map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) }
            ?? timestamp.prefix(10).description
    }

    var preview: String {
        String(content.prefix(120)).replacingOccurrences(of: "\n", with: " ")
    }

    var searchableText: String { (id + " " + content + " " + source).lowercased() }

    init(row: [String: String]) {
        id = row["id"] ?? ""
        content = row["content"] ?? ""
        source = row["source"] ?? ""
        timestamp = row["timestamp"] ?? ""
        importance = Double(row["importance"] ?? "0.5") ?? 0.5
        veracity = row["veracity"] ?? "unknown"
        scope = row["scope"] ?? "global"
        recallCount = Int(row["recall_count"] ?? "0") ?? 0
        lastRecalled = row["last_recalled"] ?? ""
        sessionId = row["session_id"] ?? "default"
    }

    static func search(query: String, limit: Int = 30) -> [MemoryItem] {
        MnemosyneService.search(query: query, limit: limit)
    }

    static func all(limit: Int = 30) -> [MemoryItem] {
        MnemosyneService.all(limit: limit)
    }

    static func update(id: String, content: String) {
        MnemosyneService.update(id: id, content: content)
    }
}
