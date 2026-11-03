import AppKit
import CoreAudio
import UniformTypeIdentifiers

/// Un proceso que Core Audio conoce (cualquier programa que abrió el audio).
struct AudioProcess: Identifiable {
    let objectID: AudioObjectID   // id del proceso dentro de Core Audio (NO es el PID)
    let pid: pid_t
    let key: String               // agrupa procesos de la misma app (Chrome + sus Helpers)
    let name: String
    let icon: NSImage
    var isPlaying: Bool

    var id: AudioObjectID { objectID }

    init?(objectID: AudioObjectID) {
        let pid: pid_t = objectID.read(kAudioProcessPropertyPID, default: -1)
        guard pid > 0, pid != getpid() else { return nil }   // ignoramos a SoundMaster

        self.objectID = objectID
        self.pid = pid
        self.isPlaying = Self.isRunningOutput(objectID)

        let bundleID = objectID.readString(kAudioProcessPropertyBundleID) ?? ""
        let path = Self.executablePath(of: pid)

        if let appURL = path.flatMap(Self.enclosingApp) {
            // Proceso dentro de un .app (incluye "Google Chrome Helper" → "Google Chrome")
            key = Bundle(url: appURL)?.bundleIdentifier ?? appURL.path
            name = Self.displayName(of: appURL)
            icon = NSWorkspace.shared.icon(forFile: appURL.path)
        } else if bundleID.hasPrefix("com.apple.WebKit") {
            // Safari reproduce el audio desde un proceso de WebKit
            key = bundleID
            name = "Safari / WebKit"
            icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")
                .map { NSWorkspace.shared.icon(forFile: $0.path) } ?? Self.genericIcon
        } else {
            // Herramientas de línea de comandos (afplay, etc.)
            key = bundleID.isEmpty ? (path ?? "pid-\(pid)") : bundleID
            name = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? (bundleID.isEmpty ? "PID \(pid)" : bundleID)
            icon = path.map { NSWorkspace.shared.icon(forFile: $0) } ?? Self.genericIcon
        }
    }

    static func isRunningOutput(_ objectID: AudioObjectID) -> Bool {
        let running: UInt32 = objectID.read(kAudioProcessPropertyIsRunningOutput, default: 0)
        return running != 0
    }

    // MARK: - Ayudantes

    private static let genericIcon = NSWorkspace.shared.icon(for: .application)

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// "/Applications/Google Chrome.app/Contents/Frameworks/…/Helper.app/…" → "/Applications/Google Chrome.app"
    private static func enclosingApp(of path: String) -> URL? {
        let parts = path.split(separator: "/")
        guard let index = parts.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return URL(fileURLWithPath: "/" + parts[...index].joined(separator: "/"))
    }

    private static func displayName(of appURL: URL) -> String {
        let name = FileManager.default.displayName(atPath: appURL.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
