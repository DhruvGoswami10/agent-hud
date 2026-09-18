import AppKit
import Combine

@MainActor
final class WatchBridge: ObservableObject {
    static let shared = WatchBridge()
    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: "watchBridgeEnabled")
    @Published private(set) var status = "Off"
    @Published private(set) var pairingLink = ""
    private var process: Process?
    private var generation = 0
    private var terminating = false

    func setEnabled(_ value: Bool) {
        enabled = value
        UserDefaults.standard.set(value, forKey: "watchBridgeEnabled")
        value ? start() : stop()
    }

    func start() {
        guard enabled, process == nil, !Playground.on else { return }
        generation += 1
        let version = generation
        status = "Preparing secure connection…"
        let script = SupportPaths.bin.appendingPathComponent("agent-hud-watch-bridge").path
        let directory = SupportPaths.directory.path
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> String? in
                let p = Process(); p.executableURL = URL(fileURLWithPath: script)
                p.arguments = ["--directory", directory, "--prepare"]
                let output = Pipe(); p.standardOutput = output; p.standardError = FileHandle.nullDevice
                do {
                    try p.run()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    guard p.terminationStatus == 0,
                          let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                    return json["link"] as? String
                } catch { return nil }
            }.value
            guard let self, self.enabled, self.generation == version, !self.terminating else { return }
            guard let result else { status = "Could not prepare pairing; Python 3 and OpenSSL are required"; return }
            pairingLink = result
            let p = Process(); p.executableURL = URL(fileURLWithPath: script)
            p.arguments = ["--directory", directory, "--local-port", String(Playground.port)]
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == version, !self.terminating else { return }
                    self.process = nil
                    self.status = "Connection stopped; check that port 48087 is available"
                }
            }
            do { try p.run(); process = p; status = "Secure read-only relay on port 48087" }
            catch { status = "Could not start Watch relay" }
        }
    }

    func stop(terminating: Bool = false) {
        self.terminating = terminating
        generation += 1
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        pairingLink = ""
        status = "Off"
    }

    func copyPairingLink() {
        guard !pairingLink.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(pairingLink, forType: .string)
        pb.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
    }
}
