import Foundation
import MCP

final class MailService: Sendable {
    private let accountAddress = ProcessInfo.processInfo.environment["LOCAL_MAC_MCP_ICLOUD_EMAIL"]?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    func call(_ name: String, _ arguments: [String: Value]) async throws -> String {
        guard !accountAddress.isEmpty else {
            throw Err.message("Set LOCAL_MAC_MCP_ICLOUD_EMAIL in the local .env file, then restart make run.")
        }
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
        case "list_icloud_mail_attachments":
            let id = try messageID(arguments)
            let attachments = try await attachmentsForMessage(id)
            return try encode(attachments)
        case "download_icloud_mail_attachment":
            let id = try messageID(arguments)
            guard let attachmentID = arguments["attachment_id"]?.stringValue, !attachmentID.isEmpty else {
                throw Err.message("Provide an attachment_id returned by list_icloud_mail_attachments.")
            }
            let attachments = try await attachmentsForMessage(id)
            guard let selected = attachments.first(where: { $0["id"] as? String == attachmentID }),
                  let originalName = selected["name"] as? String else {
                throw Err.message("Attachment ID not found in the selected iCloud message.")
            }
            guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw Err.message("Cannot locate the user's Application Support folder.")
            }
            let folder = support.appendingPathComponent("LocalMacAppIntegrations/Attachments/\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(safeFileName(originalName), isDirectory: false)
            _ = try await runBridge("save_attachment", String(id), 1, extra: [attachmentID, destination.path])
            guard FileManager.default.fileExists(atPath: destination.path) else {
                throw Err.message("Apple Mail did not create the attachment file at the expected path.")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            return try encode([[
                "message_id": id,
                "attachment_id": attachmentID,
                "name": originalName,
                "path": destination.path,
                "size_bytes": attributes[.size] as? Int ?? 0,
            ]])
        default:
            throw Err.message("Unknown Mail tool: \(name)")
        }
    }

    private func messageID(_ arguments: [String: Value]) throws -> Int {
        guard let id = arguments["id"]?.intValue, id > 0 else {
            throw Err.message("Provide the numeric message ID returned by search_icloud_mail.")
        }
        return id
    }

    private func attachmentsForMessage(_ id: Int) async throws -> [[String: Any]] {
        let lines = try await runBridge("attachments", String(id), 1)
        if lines.isEmpty { return [] }
        return try lines.split(separator: "\n").map { try parseAttachmentLine(String($0)) }
    }

    private func safeFileName(_ name: String) -> String {
        let component = (name as NSString).lastPathComponent
        let clean = String(component.map { character in
            character == "/" || character == ":" || character == "\\" || character.isNewline ? "_" : character
        }.prefix(180)).trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty || clean == "." || clean == ".." ? "attachment" : clean
    }

    private func runBridge(_ operation: String, _ value: String, _ limit: Int, extra: [String] = []) async throws -> String {
        let accountAddress = self.accountAddress
        return try await Task.detached(priority: .userInitiated) {
            try Self.runBridgeSync(operation, accountAddress, value, limit, extra)
        }.value
    }

    private static func runBridgeSync(_ operation: String, _ accountAddress: String, _ value: String, _ limit: Int, _ extra: [String]) throws -> String {
        guard let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("MailBridge.applescript"),
              FileManager.default.fileExists(atPath: resourceURL.path) else {
            throw Err.message("MailBridge.applescript is missing from the app bundle. Rebuild with make run.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [resourceURL.path, operation, accountAddress, value, String(limit)] + extra
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

    private func parseAttachmentLine(_ line: String) throws -> [String: Any] {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 5, let size = Int(fields[3]) else {
            throw Err.message("Apple Mail returned an unexpected attachment format.")
        }
        return [
            "id": try decode(fields[0]),
            "name": try decode(fields[1]),
            "mime_type": try decode(fields[2]),
            "size_bytes": size,
            "downloaded_in_mail": fields[4] == "true",
        ]
    }

    private func encode(_ items: [[String: Any]]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: items, options: [.fragmentsAllowed, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
