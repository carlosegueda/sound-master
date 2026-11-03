import CoreAudio
import Foundation

/// Vigila qué procesos usan audio y avisa cada vez que algo cambia.
@MainActor
final class ProcessMonitor {
    var onChange: (([AudioProcess]) -> Void)?

    private var cache: [AudioObjectID: AudioProcess] = [:]
    private var listener: PropertyListener?
    private var timer: Timer?

    func start() {
        // 1. Aviso inmediato cuando un proceso abre o cierra el audio
        listener = PropertyListener(object: .system,
                                    selector: kAudioHardwarePropertyProcessObjectList) { [weak self] in
            self?.refresh()
        }
        // 2. Revisión cada segundo para saber quién empezó o dejó de sonar
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
                // Ya lo conocíamos: solo actualizamos si está sonando (barato)
                known.isPlaying = AudioProcess.isRunningOutput(id)
                next[id] = known
            } else if let process = AudioProcess(objectID: id) {
                // Proceso nuevo: calculamos nombre e ícono una sola vez
                next[id] = process
            }
        }

        cache = next
        onChange?(Array(next.values))
    }
}
