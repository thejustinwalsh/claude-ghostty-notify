import Foundation
import UserNotifications
import AppKit
import SQLite3

// MARK: - Logging

let logFile = FileHandle(forWritingAtPath: "/tmp/claude-notify.log")
    ?? { FileManager.default.createFile(atPath: "/tmp/claude-notify.log", contents: nil)
         return FileHandle(forWritingAtPath: "/tmp/claude-notify.log")! }()

func log(_ msg: String) {
    logFile.seekToEndOfFile()
    logFile.write("[\(Date())] \(msg)\n".data(using: .utf8)!)
}

// MARK: - Session Store (SQLite)

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

class SessionStore {
    private var db: OpaquePointer?

    static var defaultPath: String {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.claude.notify").path
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: nil)
        return dir + "/store.db"
    }

    init(dbPath: String? = nil) {
        let path = dbPath ?? SessionStore.defaultPath
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            log("failed to open database at \(path)")
            return
        }

        exec("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS sessions (
                session_id TEXT PRIMARY KEY,
                terminal_uuid TEXT,
                updated_at REAL DEFAULT (strftime('%s','now'))
            );
            CREATE TABLE IF NOT EXISTS notifications (
                notif_id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                created_at REAL DEFAULT (strftime('%s','now'))
            );
        """)

        purge()
    }

    deinit {
        sqlite3_close(db)
    }

    @discardableResult
    func exec(_ sql: String) -> Bool {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            if let err = err {
                log("SQL error: \(String(cString: err))")
                sqlite3_free(err)
            }
            return false
        }
        return true
    }

    func purge() {
        exec("""
            DELETE FROM sessions WHERE updated_at < strftime('%s','now') - 86400;
            DELETE FROM notifications WHERE created_at < strftime('%s','now') - 86400;
        """)
    }

    // MARK: Terminal UUID

    func setTerminalUUID(_ uuid: String, forSession sessionId: String) {
        var stmt: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO sessions (session_id, terminal_uuid, updated_at) VALUES (?, ?, strftime('%s','now'))"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, uuid, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    func getTerminalUUID(forSession sessionId: String) -> String? {
        var stmt: OpaquePointer?
        let sql = "SELECT terminal_uuid FROM sessions WHERE session_id = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let cStr = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cStr)
    }

    // MARK: Notification IDs

    func addNotificationId(_ notifId: String, forSession sessionId: String) {
        var stmt: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO notifications (notif_id, session_id, created_at) VALUES (?, ?, strftime('%s','now'))"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, notifId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, sessionId, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    func getAndClearNotificationIds(forSession sessionId: String) -> [String] {
        var ids: [String] = []

        // Read
        var stmt: OpaquePointer?
        let sql = "SELECT notif_id FROM notifications WHERE session_id = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                ids.append(String(cString: cStr))
            }
        }
        sqlite3_finalize(stmt)

        // Delete
        if !ids.isEmpty {
            var delStmt: OpaquePointer?
            let delSql = "DELETE FROM notifications WHERE session_id = ?"
            if sqlite3_prepare_v2(db, delSql, -1, &delStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(delStmt, 1, sessionId, -1, SQLITE_TRANSIENT)
                sqlite3_step(delStmt)
                sqlite3_finalize(delStmt)
            }
        }

        return ids
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var inputCwd = ""
    let store = SessionStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Explicitly set app icon so macOS notification center picks it up
        // (works even if LaunchServices has a stale cache)
        if let iconPath = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let icon = NSImage(contentsOfFile: iconPath) {
            NSApp.applicationIconImage = icon
        }

        let args = CommandLine.arguments

        // Dismiss mode: remove delivered notifications for a specific session
        if args.count > 1 && args[1].hasPrefix("dismiss") {
            let center = UNUserNotificationCenter.current()
            let sessionId = args[1].contains(":") ? String(args[1].dropFirst("dismiss:".count)) : nil

            if let sessionId = sessionId, !sessionId.isEmpty {
                let ids = store.getAndClearNotificationIds(forSession: sessionId)
                if !ids.isEmpty {
                    center.removeDeliveredNotifications(withIdentifiers: ids)
                }
                log("dismissed \(ids.count) notifications for session \(sessionId)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NSApp.terminate(nil)
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

        // No args — nothing to do (permissions are requested on first real notification)
        if args.count <= 1 {
            log("launched with no args, exiting")
            NSApp.terminate(nil)
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
                    self.store.addNotificationId(request.identifier, forSession: sessionId)
                    log("notification sent successfully (id=\(request.identifier))")
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

        // Look up terminal UUID from store
        var terminalUUID = ""
        if !sessionId.isEmpty {
            terminalUUID = store.getTerminalUUID(forSession: sessionId) ?? ""
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

// MARK: - Tests

struct TestRunner {
    var passed = 0
    var failed = 0

    mutating func assert(_ condition: Bool, _ msg: String, line: Int = #line) {
        if condition {
            passed += 1
            print("  PASS \(msg)")
        } else {
            failed += 1
            print("  FAIL \(msg) (line \(line))")
        }
    }

    mutating func run() -> Bool {
        let store = SessionStore(dbPath: ":memory:")

        print("SessionStore — Terminal UUID:")

        store.setTerminalUUID("UUID-AAA", forSession: "sess-1")
        assert(store.getTerminalUUID(forSession: "sess-1") == "UUID-AAA",
               "store and retrieve terminal UUID")

        store.setTerminalUUID("UUID-BBB", forSession: "sess-1")
        assert(store.getTerminalUUID(forSession: "sess-1") == "UUID-BBB",
               "overwrite terminal UUID")

        assert(store.getTerminalUUID(forSession: "sess-missing") == nil,
               "missing session returns nil")

        store.setTerminalUUID("UUID-CCC", forSession: "sess-2")
        assert(store.getTerminalUUID(forSession: "sess-1") == "UUID-BBB",
               "other session insert doesn't affect existing")

        print("\nSessionStore — Notification IDs:")

        store.addNotificationId("notif-1", forSession: "sess-1")
        store.addNotificationId("notif-2", forSession: "sess-1")
        store.addNotificationId("notif-3", forSession: "sess-2")

        let ids1 = store.getAndClearNotificationIds(forSession: "sess-1")
        assert(ids1.count == 2, "retrieves correct count for session")
        assert(ids1.contains("notif-1") && ids1.contains("notif-2"),
               "retrieves correct notification IDs")

        let ids1Again = store.getAndClearNotificationIds(forSession: "sess-1")
        assert(ids1Again.isEmpty, "IDs cleared after retrieval")

        let ids2 = store.getAndClearNotificationIds(forSession: "sess-2")
        assert(ids2 == ["notif-3"], "session isolation — sess-2 unaffected")

        let idsEmpty = store.getAndClearNotificationIds(forSession: "sess-never")
        assert(idsEmpty.isEmpty, "non-existent session returns empty")

        print("\nSessionStore — Auto-purge:")

        store.setTerminalUUID("UUID-OLD", forSession: "sess-old")
        store.addNotificationId("notif-old", forSession: "sess-old")
        // Backdate entries to 25 hours ago
        store.exec("UPDATE sessions SET updated_at = strftime('%s','now') - 90000 WHERE session_id = 'sess-old'")
        store.exec("UPDATE notifications SET created_at = strftime('%s','now') - 90000 WHERE session_id = 'sess-old'")

        store.purge()

        assert(store.getTerminalUUID(forSession: "sess-old") == nil,
               "purge removes old sessions")
        assert(store.getAndClearNotificationIds(forSession: "sess-old").isEmpty,
               "purge removes old notifications")
        assert(store.getTerminalUUID(forSession: "sess-1") == "UUID-BBB",
               "purge preserves recent sessions")
        assert(store.getTerminalUUID(forSession: "sess-2") == "UUID-CCC",
               "purge preserves other recent sessions")

        print("\nSessionStore — Duplicate notification IDs:")

        store.addNotificationId("dup-1", forSession: "sess-dup")
        store.addNotificationId("dup-1", forSession: "sess-dup")
        let dupIds = store.getAndClearNotificationIds(forSession: "sess-dup")
        assert(dupIds.count == 1, "duplicate notification ID stored once (PRIMARY KEY)")

        print("\n\(passed) passed, \(failed) failed")
        return failed == 0
    }
}

// MARK: - Main

if CommandLine.arguments.contains("--test") {
    var runner = TestRunner()
    exit(runner.run() ? 0 : 1)
}

let appDelegate = AppDelegate()
let app = NSApplication.shared
app.delegate = appDelegate
app.run()
