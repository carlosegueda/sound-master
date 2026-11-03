import CoreAudio
import Foundation

/// Watches which processes use audio and notifies whenever something changes.
@MainActor
final class ProcessMonitor {
    var onChange: (([AudioProcess]) -> Void)?

    private var cache: [AudioObjectID: AudioProcess] = [:]
    private var listener: PropertyListener?
    private var timer: Timer?

    func start() {
        // 1. Immediate notification when a process opens or closes audio
        listener = PropertyListener(object: .system,
                                    selector: kAudioHardwarePropertyProcessObjectList) { [weak self] in
            self?.refresh()
        }
        // 2. Poll every second to detect which processes started or stopped playing
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        let ids = AudioObjectID.system.readArray(kAudioHardwarePropertyProcessObjectList)
        var next: [AudioObjectID: AudioProcess] = [:]

        for id in ids {
            if var known = cache[id] {
                // Already known: only update whether it is playing (cheap)
                known.isPlaying = AudioProcess.isRunningOutput(id)
                next[id] = known
            } else if let process = AudioProcess(objectID: id) {
                // New process: resolve name and icon only once
                next[id] = process
            }
        }

        cache = next
        onChange?(Array(next.values))
    }
}
