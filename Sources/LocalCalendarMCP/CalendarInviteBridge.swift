import Foundation

enum CalendarInviteBridge {
    static func invite(calendarName: String, title: String, startParts: [Int], email: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try run(calendarName: calendarName, title: title, startParts: startParts, email: email)
        }.value
    }

    private static func run(calendarName: String, title: String, startParts: [Int], email: String) throws -> String {
        guard let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("CalendarInviteBridge.applescript"),
              FileManager.default.fileExists(atPath: resourceURL.path) else {
            throw Err.message("CalendarInviteBridge.applescript is missing from the app bundle. Rebuild with make run.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [resourceURL.path, "invite", calendarName, title] + startParts.map(String.init) + [email]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch { throw Err.message("Could not start Calendar automation: \(error.localizedDescription)") }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let detail = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
            throw Err.message("Calendar invitation failed: \(detail). Check System Settings → Privacy & Security → Automation and allow Calendar control for this server.")
        }
        let status = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard status == "added" || status == "already_present" else {
            throw Err.message("Calendar returned an unexpected invitation status.")
        }
        return status
    }
}
