import Foundation

enum FleetAPIError: Error { case badURL, requestFailed, decodeFailed }

@MainActor
enum FleetAPIClient {
    static let base = "http://127.0.0.1:8788"

    static func get<T: Decodable>(_ path: String) async throws -> T {
        guard let url = URL(string: base + path) else { throw FleetAPIError.badURL }
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode ?? 0 < 400 else { throw FleetAPIError.requestFailed }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func post(_ path: String, body: [String: Any]) async throws -> (Int, Data) {
        guard let url = URL(string: base + path) else { throw FleetAPIError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return (code, data)
    }

    static func post<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        guard let url = URL(string: base + path) else { throw FleetAPIError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode ?? 0 < 400 else { throw FleetAPIError.requestFailed }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
