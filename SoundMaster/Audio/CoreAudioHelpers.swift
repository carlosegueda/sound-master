import CoreAudio
import Foundation

// MARK: - Lectura y escritura de propiedades de Core Audio

extension AudioObjectID {
    /// El objeto "sistema": de él cuelgan los dispositivos y los procesos.
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    /// Dispositivo de salida actual (bocinas, audífonos, AirPods…).
    static var defaultOutputDevice: AudioObjectID {
        system.read(kAudioHardwarePropertyDefaultOutputDevice, default: unknown)
    }

    func propertyAddress(_ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Lee una propiedad de tamaño fijo (UInt32, Float32, pid_t, AudioObjectID, structs…).
    func read<T: BitwiseCopyable>(_ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                 default value: T) -> T {
        var address = propertyAddress(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        var result = value
        let status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &result)
        return status == noErr ? result : value
    }

    /// Lee una propiedad de texto (nombre, UID, bundle ID).
    func readString(_ selector: AudioObjectPropertySelector) -> String? {
        var address = propertyAddress(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// Lee una propiedad que es una lista de objetos (procesos, dispositivos…).
    func readArray(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = propertyAddress(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    @discardableResult
    func write<T: BitwiseCopyable>(_ selector: AudioObjectPropertySelector,
                  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                  value: T) -> Bool {
        var address = propertyAddress(selector, scope: scope)
        var value = value
        return AudioObjectSetPropertyData(self, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value) == noErr
    }

    func isSettable(_ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var address = propertyAddress(selector, scope: scope)
        guard AudioObjectHasProperty(self, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(self, &address, &settable) == noErr && settable.boolValue
    }
}

// MARK: - Escuchar cambios

/// Avisa (en el hilo principal) cuando cambia una propiedad de Core Audio.
/// Mientras el objeto exista, escucha; al liberarse, deja de escuchar.
final class PropertyListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock

    init(object: AudioObjectID,
         selector: AudioObjectPropertySelector,
         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
         handler: @escaping @MainActor () -> Void) {
        self.object = object
        self.address = object.propertyAddress(selector, scope: scope)
        self.block = { _, _ in MainActor.assumeIsolated { handler() } }
        AudioObjectAddPropertyListenerBlock(object, &address, .main, block)
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
    }
}
