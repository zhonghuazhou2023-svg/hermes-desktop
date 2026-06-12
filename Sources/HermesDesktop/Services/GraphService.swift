import Foundation
import SQLite3

struct GraphNode: Codable, Identifiable {
    var id: String { nodeId }
    let nodeId: String
    let label: String
    let group: String
    let importance: Double
    let preview: String

    static func from(row: [String: String]) -> GraphNode {
        let content = row["content"] ?? ""
        let source = row["source"] ?? ""
        return GraphNode(
            nodeId: row["id"] ?? UUID().uuidString,
            label: String(content.prefix(40)).replacingOccurrences(of: "\n", with: " "),
            group: source,
            importance: Double(row["importance"] ?? "0.5") ?? 0.5,
            preview: String(content.prefix(200))
        )
    }
}

struct GraphEdge: Codable, Identifiable {
    var id: String { "\(source)-\(target)-\(label)" }
    let source: String
    let target: String
    let label: String
    let weight: Double

    init(source: String, target: String, label: String = "related", weight: Double = 1.0) {
        self.source = source
        self.target = target
        self.label = label
        self.weight = weight
    }
}

struct GraphData: Codable {
    let nodes: [GraphNode]
    let edges: [GraphEdge]
}

enum GraphService {
    private static let dbPath = NSHomeDirectory() + "/.hermes/mnemosyne/data/mnemosyne.db"

    private static func openDB() -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else { return nil }
        return db
    }

    static func buildGraph(searchQuery: String = "", limit: Int = 50) -> GraphData {
        let nodes = fetchNodes(search: searchQuery, limit: limit)
        let explicitEdges = fetchGraphEdges()
        let tripleEdges = fetchTripleEdges()
        let relatedEdges = computeRelatedEdges(from: nodes)

        var edgeMap: [String: GraphEdge] = [:]
        for edge in explicitEdges + tripleEdges + relatedEdges {
            edgeMap[edge.id] = edge
        }
        return GraphData(nodes: nodes, edges: Array(edgeMap.values))
    }

    private static func fetchNodes(search: String, limit: Int) -> [GraphNode] {
        guard let db = openDB() else { return [] }
        defer { sqlite3_close(db) }

        let sql: String
        if search.isEmpty {
            sql = "SELECT * FROM working_memory ORDER BY importance DESC, timestamp DESC LIMIT ?"
        } else {
            sql = """
                SELECT wm.* FROM working_memory wm
                JOIN fts_working fts ON wm.id = fts.id
                WHERE fts_working MATCH ?
                ORDER BY wm.importance DESC LIMIT ?
                """
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        if search.isEmpty {
            sqlite3_bind_int(stmt, 1, Int32(limit))
        } else {
            sqlite3_bind_text(stmt, 1, search, -1, nil)
            sqlite3_bind_int(stmt, 2, Int32(limit))
        }

        var nodes: [GraphNode] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            nodes.append(GraphNode.from(row: rowDict(from: stmt)))
        }
        return nodes
    }

    private static func fetchGraphEdges() -> [GraphEdge] {
        guard let db = openDB() else { return [] }
        defer { sqlite3_close(db) }

        let sql = "SELECT source, target, edge_type, weight FROM graph_edges"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var edges: [GraphEdge] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let source = String(cString: sqlite3_column_text(stmt, 0))
            let target = String(cString: sqlite3_column_text(stmt, 1))
            let label = String(cString: sqlite3_column_text(stmt, 2))
            let weight = sqlite3_column_double(stmt, 3)
            edges.append(GraphEdge(source: source, target: target, label: label, weight: weight))
        }
        return edges
    }

    private static func fetchTripleEdges() -> [GraphEdge] {
        guard let db = openDB() else { return [] }
        defer { sqlite3_close(db) }

        let sql = "SELECT subject, predicate, object FROM triples"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var edges: [GraphEdge] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let subject = String(cString: sqlite3_column_text(stmt, 0))
            let predicate = String(cString: sqlite3_column_text(stmt, 1))
            let object = String(cString: sqlite3_column_text(stmt, 2))
            edges.append(GraphEdge(source: subject, target: object, label: predicate, weight: 1.0))
        }
        return edges
    }

    private static func computeRelatedEdges(from nodes: [GraphNode]) -> [GraphEdge] {
        guard nodes.count <= 50 else { return [] }
        var edges: [GraphEdge] = []
        let keywords: [String: Set<String>] = Dictionary(uniqueKeysWithValues: nodes.map { node in
            let words = Set(
                node.preview.lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { $0.count > 2 }
            )
            return (node.nodeId, words)
        })
        let ids = nodes.map(\.nodeId)
        for i in 0..<ids.count {
            for j in (i + 1)..<ids.count {
                let common = keywords[ids[i]]?.intersection(keywords[ids[j]] ?? []) ?? []
                if common.count >= 3 {
                    edges.append(
                        GraphEdge(
                            source: ids[i],
                            target: ids[j],
                            label: "shared:\(common.first ?? "")",
                            weight: Double(common.count) / 10.0
                        )
                    )
                }
            }
        }
        return edges
    }

    private static func rowDict(from stmt: OpaquePointer?) -> [String: String] {
        guard let stmt else { return [:] }
        var dict: [String: String] = [:]
        let count = sqlite3_column_count(stmt)
        for i in 0..<count {
            let name = String(cString: sqlite3_column_name(stmt, i))
            let value = sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? ""
            dict[name] = value
        }
        return dict
    }
}
