import Foundation
import Security

enum SupportPaths {
    static var sourceRoot: URL {
        if let root = ProcessInfo.processInfo.environment["AGENT_HUD_ROOT"] {
            return URL(fileURLWithPath: root)
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static var bin: URL {
        if ProcessInfo.processInfo.environment["AGENT_HUD_ROOT"] != nil {
            return sourceRoot.appendingPathComponent("bin")
        }
        if let resources = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: resources.appendingPathComponent("bin/agent-hud-registry").path) {
            return resources.appendingPathComponent("bin")
        }
        return sourceRoot.appendingPathComponent("bin")
    }

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Playground.on ? "AgentHUD Playground" : "AgentHUD")
    }

    static func config(_ name: String) -> URL {
        for root in [directory, sourceRoot, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("agent-hud")] {
            let path = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: path.path) { return path }
        }
        return directory.appendingPathComponent(name)
    }

    static func browserToken() -> String {
        let path = directory.appendingPathComponent("browser-token")
        if let token = try? String(contentsOf: path, encoding: .utf8), token.count == 64 { return token }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return "" }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            try Data(token.utf8).write(to: path, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            return token
        } catch { return "" }
    }
}
