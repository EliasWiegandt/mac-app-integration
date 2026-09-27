import Foundation
import MCP

final class MailService: Sendable {
    private let accountAddress = "you@icloud.com"

    func call(_ name: String, _ arguments: [String: Value]) async throws -> String {
        switch name {
        case "search_icloud_mail":
            guard let query = arguments["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !query.isEmpty else { throw Err.message("Provide a nonempty query to search message subjects and senders.") }
            let limit = arguments["limit"]?.intValue ?? 20
            guard (1...50).contains(limit) else { throw Err.message("limit must be between 1 and 50.") }
            let lines = try await runBridge("search", query, limit)
            let items = try lines.split(separator: "\n").map { try parseLine(String($0), includesBody: false) }
            return try encode(items)
        case "read_icloud_mail":
            guard let id = arguments["id"]?.intValue, id > 0 else { throw Err.message("Provide the numeric message ID returned by search_icloud_mail.") }
            let line = try await runBridge("read", String(id), 1)
            return try encode([try parseLine(line, includesBody: true)])
        default:
            throw Err.message("Unknown Mail tool: \(name)")
        }
    }

    private func runBridge(_ operation: String, _ value: String, _ limit: Int) async throws -> String {
        let accountAddress = self.accountAddress
        return try await Task.detached(priority: .userInitiated) {
            try Self.runBridgeSync(operation, accountAddress, value, limit)
        }.value
    }

    private static func runBridgeSync(_ operation: String, _ accountAddress: String, _ value: String, _ limit: Int) throws -> String {
        guard let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("MailBridge.applescript"),
              FileManager.default.fileExists(atPath: resourceURL.path) else {
            throw Err.message("MailBridge.applescript is missing from the app bundle. Rebuild with make run.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [resourceURL.path, operation, accountAddress, value, String(limit)]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch { throw Err.message("Could not start Apple Mail automation: \(error.localizedDescription)") }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let detail = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
            throw Err.message("Apple Mail automation failed: \(detail). Check System Settings → Privacy & Security → Automation and allow Mail control for this server.")
        }
        return String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .newlines) ?? ""
    }

    private func parseLine(_ line: String, includesBody: Bool) throws -> [String: Any] {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == (includesBody ? 7 : 6), let id = Int(fields[0]) else {
            throw Err.message("Apple Mail returned an unexpected message format.")
        }
        var item: [String: Any] = [
            "id": id,
            "subject": try decode(fields[1]),
            "sender": try decode(fields[2]),
            "date_received": try decode(fields[3]),
            "mailbox": try decode(fields[4]),
            "read": fields[5] == "true",
            "account": accountAddress,
        ]
        if includesBody { item["body"] = try decode(fields[6]) }
        return item
    }

    private func decode(_ field: String) throws -> String {
        guard let data = Data(base64Encoded: field), let text = String(data: data, encoding: .utf8) else {
            throw Err.message("Apple Mail returned invalid message text.")
        }
        return text
    }

    private func encode(_ items: [[String: Any]]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: items, options: [.fragmentsAllowed, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
