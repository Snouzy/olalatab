import Foundation

public struct Config: Codable, Equatable {
    public var order: WindowOrder

    public init(order: WindowOrder = .creation) {
        self.order = order
    }

    private enum CodingKeys: String, CodingKey { case order }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        order = try c.decodeIfPresent(WindowOrder.self, forKey: .order) ?? .creation
    }

    public static let `default` = Config()

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/olalatab/config.json")
    }

    public enum LoadError: Error, CustomStringConvertible {
        case invalid(String)

        public var description: String {
            switch self { case .invalid(let message): return message }
        }
    }

    public static func decode(_ data: Data) throws -> Config {
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch DecodingError.dataCorrupted(let context) where context.codingPath.last?.stringValue == "order" {
            let allowed = WindowOrder.allCases.map(\.rawValue).joined(separator: ", ")
            throw LoadError.invalid("\"order\" must be one of: \(allowed)")
        } catch {
            throw LoadError.invalid("\(error)")
        }
    }

    public static func load(from url: URL) throws -> Config {
        try decode(Data(contentsOf: url))
    }

    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
