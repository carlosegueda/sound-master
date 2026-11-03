import AppKit
import AudioToolbox
import CoreAudio
import Observation

/// El cerebro del mezclador: une el monitor de procesos, los taps y la UI.
@MainActor
@Observable
final class MixerStore {
    /// Una fila del mezclador = una app (puede tener varios procesos).
    struct AppChannel: Identifiable, Equatable {
        let id: String
        let name: String
        let icon: NSImage
        var processIDs: [AudioObjectID]

        static func == (a: AppChannel, b: AppChannel) -> Bool {
            a.id == b.id && a.processIDs == b.processIDs
        }
    }

    // MARK: Estado que ve la UI
    private(set) var channels: [AppChannel] = []
    private(set) var outputName = ""
    private(set) var masterVolume: Float = 0
    private(set) var hasMasterVolume = false
    private(set) var errorMessage: String?
    private var volumes: [String: Double]   // por app, se guarda en disco
    private var muted: Set<String>

    // MARK: Estado interno
    @ObservationIgnored private var taps: [AudioObjectID: AppVolumeTap] = [:]
    @ObservationIgnored private var failed: Set<AudioObjectID> = []
    @ObservationIgnored private let monitor = ProcessMonitor()
    @ObservationIgnored private var outputDevice = AudioObjectID.unknown
    @ObservationIgnored private var deviceListener: PropertyListener?
    @ObservationIgnored private var masterListener: PropertyListener?

    private static let masterSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
    private static let outputScope = kAudioDevicePropertyScopeOutput

    init() {
        volumes = UserDefaults.standard.dictionary(forKey: Keys.volumes) as? [String: Double] ?? [:]
        muted = Set(UserDefaults.standard.stringArray(forKey: Keys.muted) ?? [])

        outputDevice = .defaultOutputDevice
        configureOutput()
        deviceListener = PropertyListener(object: .system,
                                          selector: kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            self?.outputDeviceChanged()
        }

        monitor.onChange = { [weak self] processes in self?.update(with: processes) }
        monitor.start()
    }

    // MARK: - Acciones desde la UI

    func volume(for id: String) -> Float { Float(volumes[id] ?? 1) }
    func isMuted(_ id: String) -> Bool { muted.contains(id) }

    func setVolume(_ value: Float, for id: String) {
        volumes[id] = Double(value)
        applyGain(to: id)
        save()
    }

    func toggleMute(_ id: String) {
        if muted.contains(id) { muted.remove(id) } else { muted.insert(id) }
        applyGain(to: id)
        save()
    }

    func setMasterVolume(_ value: Float) {
        masterVolume = value
        outputDevice.write(Self.masterSelector, scope: Self.outputScope, value: Float32(value))
    }

    // MARK: - Procesos

    private func update(with processes: [AudioProcess]) {
        // Cerrar taps de procesos que ya no existen
        let alive = Set(processes.map(\.objectID))
        for id in taps.keys where !alive.contains(id) {
            taps.removeValue(forKey: id)?.invalidate()
        }
        failed.formIntersection(alive)

        // Agrupar por app: solo las que suenan o que ya controlamos
        var grouped: [String: AppChannel] = [:]
        for process in processes where process.isPlaying || taps[process.objectID] != nil {
            grouped[process.key, default: AppChannel(id: process.key, name: process.name,
                                                     icon: process.icon, processIDs: [])]
                .processIDs.append(process.objectID)
        }
        let next = grouped.values
            .map { var c = $0; c.processIDs.sort(); return c }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if next != channels { channels = next }

        // Aplicar volúmenes guardados a apps que acaban de aparecer
        for channel in channels { applyGain(to: channel.id) }
    }

    private func gain(for id: String) -> Float {
        muted.contains(id) ? 0 : volume(for: id)
    }

    private func applyGain(to id: String) {
        guard let channel = channels.first(where: { $0.id == id }) else { return }
        let gain = gain(for: id)

        for processID in channel.processIDs {
            if let tap = taps[processID] {
                tap.volume = gain
                continue
            }
            // Al 100 % no hace falta tap: el audio va directo, sin latencia extra
            guard gain != 1, !failed.contains(processID) else { continue }
            do {
                taps[processID] = try AppVolumeTap(process: processID, outputDevice: outputDevice, volume: gain)
                errorMessage = nil
            } catch {
                failed.insert(processID)
                errorMessage = "No se pudo controlar \(channel.name): \(error)"
            }
        }
    }

    // MARK: - Dispositivo de salida

    private func outputDeviceChanged() {
        outputDevice = .defaultOutputDevice
        configureOutput()
        // Los taps apuntan al dispositivo anterior: hay que recrearlos
        for tap in taps.values { tap.invalidate() }
        taps.removeAll()
        failed.removeAll()
        for channel in channels { applyGain(to: channel.id) }
    }

    private func configureOutput() {
        outputName = outputDevice.readString(kAudioObjectPropertyName) ?? "Salida desconocida"
        hasMasterVolume = outputDevice.isSettable(Self.masterSelector, scope: Self.outputScope)
        readMasterVolume()
        masterListener = PropertyListener(object: outputDevice, selector: Self.masterSelector,
                                          scope: Self.outputScope) { [weak self] in
            self?.readMasterVolume()
        }
    }

    private func readMasterVolume() {
        masterVolume = outputDevice.read(Self.masterSelector, scope: Self.outputScope, default: Float32(0))
    }

    // MARK: - Guardar

    private enum Keys {
        static let volumes = "appVolumes"
        static let muted = "mutedApps"
    }

    private func save() {
        UserDefaults.standard.set(volumes, forKey: Keys.volumes)
        UserDefaults.standard.set(Array(muted), forKey: Keys.muted)
    }
}
