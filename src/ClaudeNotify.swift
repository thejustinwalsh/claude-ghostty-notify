import Foundation
import UserNotifications
import AppKit

let logFile = FileHandle(forWritingAtPath: "/tmp/claude-notify.log")
    ?? { FileManager.default.createFile(atPath: "/tmp/claude-notify.log", contents: nil)
         return FileHandle(forWritingAtPath: "/tmp/claude-notify.log")! }()

func log(_ msg: String) {
    logFile.seekToEndOfFile()
    logFile.write("[\(Date())] \(msg)\n".data(using: .utf8)!)
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var inputCwd = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments

        // Dismiss mode: remove delivered notifications for a specific session
        if args.count > 1 && args[1].hasPrefix("dismiss") {
            let center = UNUserNotificationCenter.current()
            let sessionId = args[1].contains(":") ? String(args[1].dropFirst("dismiss:".count)) : nil

            if let sessionId = sessionId, !sessionId.isEmpty {
                let prefix = "claude-\(sessionId)-"
                center.getDeliveredNotifications { notifications in
                    let ids = notifications
                        .filter { $0.request.identifier.hasPrefix(prefix) }
                        .map { $0.request.identifier }
                    if !ids.isEmpty {
                        center.removeDeliveredNotifications(withIdentifiers: ids)
                    }
                    log("dismissed \(ids.count) notifications for session \(sessionId)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        NSApp.terminate(nil)
                    }
                }
            } else {
                center.removeAllDeliveredNotifications()
                log("dismissed all notifications")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NSApp.terminate(nil)
                }
            }
            return
        }

        // Setup mode: request permissions and show welcome notification
        if args.count <= 1 {
            log("setup mode: requesting notification permissions")
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                guard granted else {
                    log("permission denied: \(String(describing: error))")
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                    return
                }
                let content = UNMutableNotificationContent()
                content.title = "Ghostty Notify"
                content.subtitle = "Plugin Installed"
                content.body = "You'll be notified when Claude Code needs your attention. Click notifications to jump to the right Ghostty tab."
                content.sound = UNNotificationSound(named: UNNotificationSoundName("Tink.aiff"))
                let request = UNNotificationRequest(identifier: "claude-setup", content: content, trigger: nil)
                center.add(request) { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        NSApp.terminate(nil)
                    }
                }
            }
            return
        }

        // Arg is base64-encoded JSON
        guard let data = Data(base64Encoded: args[1]),
              let input = try? JSONDecoder().decode(HookInput.self, from: data) else {
            log("failed to decode input")
            NSApp.terminate(nil)
            return
        }

        let cwd = input.cwd ?? ""
        inputCwd = cwd
        let projectName = cwd.isEmpty ? "" : URL(fileURLWithPath: cwd).lastPathComponent
        let message = input.message ?? "Needs your attention"
        let notifType = input.notification_type ?? ""
        let hookEvent = input.hook_event_name ?? ""
        let sessionId = input.session_id ?? "unknown"

        // Git branch
        var gitBranch = ""
        if !cwd.isEmpty && FileManager.default.fileExists(atPath: "\(cwd)/.git") {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            proc.arguments = ["-C", cwd, "branch", "--show-current"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()
            gitBranch = (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Title
        var notifTitle = "Claude Code"
        if !projectName.isEmpty { notifTitle += " — \(projectName)" }

        // Subtitle
        var subtitle: String
        switch notifType {
        case "permission_prompt": subtitle = "Permission Required"
        case "idle_prompt": subtitle = "Waiting for Input"
        case "elicitation_dialog": subtitle = "Input Requested"
        case "auth_success": subtitle = "Authenticated"
        case "":
            switch hookEvent {
            case "Stop": subtitle = "Task Complete"
            default: subtitle = "Needs Attention"
            }
        default: subtitle = notifType
        }
        if !gitBranch.isEmpty { subtitle += " [\(gitBranch)]" }

        let shortMsg = String(message.prefix(250))

        // Set up notification center
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        // Request permission then send
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            guard granted else {
                log("permission denied: \(String(describing: error))")
                DispatchQueue.main.async { NSApp.terminate(nil) }
                return
            }

            let content = UNMutableNotificationContent()
            content.title = notifTitle
            content.subtitle = subtitle
            content.body = shortMsg
            content.sound = UNNotificationSound(named: UNNotificationSoundName("Tink.aiff"))
            content.userInfo = ["cwd": cwd, "sessionId": sessionId]

            let request = UNNotificationRequest(
                identifier: "claude-\(sessionId)-\(Date().timeIntervalSince1970)",
                content: content,
                trigger: nil
            )

            log("sending notification: title=\(notifTitle) subtitle=\(subtitle) body=\(shortMsg)")
            center.add(request) { error in
                if let error = error {
                    log("notification add error: \(error)")
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                } else {
                    log("notification sent successfully")
                }
            }
        }

        // Auto-exit after 30s if no click
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            NSApp.terminate(nil)
        }
    }

    // Handle notification click -> focus Ghostty tab
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler handler: @escaping () -> Void
    ) {
        log("notification clicked: \(response.actionIdentifier)")
        let cwd = response.notification.request.content.userInfo["cwd"] as? String ?? inputCwd
        let sessionId = response.notification.request.content.userInfo["sessionId"] as? String ?? ""

        // Try to read saved terminal UUID for this session
        var terminalUUID = ""
        if !sessionId.isEmpty {
            let path = "/tmp/claude-ghostty/\(sessionId)"
            if let data = FileManager.default.contents(atPath: path),
               let uuid = String(data: data, encoding: .utf8) {
                terminalUUID = uuid.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let script: String
        if !terminalUUID.isEmpty {
            script = """
            tell application "Ghostty"
                activate
                focus (first terminal whose id is "\(terminalUUID)")
            end tell
            """
        } else {
            script = "tell application \"Ghostty\" to activate"
        }

        log("running focus script, tid=\(terminalUUID), cwd=\(cwd)")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let errPipe = Pipe()
        proc.standardError = errPipe
        try? proc.run()
        proc.waitUntilExit()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        if let errStr = String(data: errData, encoding: .utf8), !errStr.isEmpty {
            log("osascript error: \(errStr)")
        }
        log("focus script done, exit=\(proc.terminationStatus)")

        handler()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }

    // Show banner even if app is frontmost
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        handler([.banner, .sound])
    }
}

// MARK: - Input model

struct HookInput: Decodable {
    var session_id: String?
    var cwd: String?
    var message: String?
    var title: String?
    var notification_type: String?
    var hook_event_name: String?
}

// MARK: - Main

let appDelegate = AppDelegate()
let app = NSApplication.shared
app.delegate = appDelegate
app.run()
