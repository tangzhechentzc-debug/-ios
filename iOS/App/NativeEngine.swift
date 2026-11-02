import Foundation

struct EngineRequest: Encodable, Sendable {
    let op: String
    var pairingRecord: String?
    var host: String?
    var port: Int?
    var serviceIdentifier: String?
    var authTag: String?
    var latitude: Double?
    var longitude: Double?
    var recoveryNeeded: Bool?
}

struct EngineReply: Decodable, Sendable {
    let ok: Bool
    let state: String?
    let message: String?
    let pairingState: String?
    let pairingCode: String?
    let pairingRecord: String?
    let serviceName: String?
    let port: Int?
    let txt: [String: String]?
    let matched: Bool?
}

protocol EngineRequesting: Sendable {
    func send(_ request: EngineRequest) async throws -> EngineReply
}

final class NativeEngine: EngineRequesting, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.tzchen.ChangeLocation.native")

    func send(_ request: EngineRequest) async throws -> EngineReply {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let encoder = JSONEncoder()
                    encoder.keyEncodingStrategy = .convertToSnakeCase
                    let data = try encoder.encode(request)
                    let json = String(decoding: data, as: UTF8.self)
                    guard let result = json.withCString({ cl_request($0) }) else {
                        throw LocationFailure(message: "原生连接服务没有返回结果。")
                    }
                    defer { cl_free(result) }
                    let decoder = JSONDecoder()
                    decoder.keyDecodingStrategy = .convertFromSnakeCase
                    let reply = try decoder.decode(EngineReply.self, from: Data(String(cString: result).utf8))
                    guard reply.ok else {
                        throw LocationFailure(message: reply.message ?? "设备请求失败，请检查本机隧道。")
                    }
                    continuation.resume(returning: reply)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
