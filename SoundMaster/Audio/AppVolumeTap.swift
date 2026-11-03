import AudioToolbox
import CoreAudio
import Foundation

/// Caja compartida entre la UI y el hilo de audio. Leer/escribir un Float es seguro aquí.
final class GainBox: @unchecked Sendable {
    var value: Float
    init(_ value: Float) { self.value = value }
}

/// Controla el volumen de UN proceso:
/// silencia su salida original, captura su audio, lo multiplica por `volume`
/// y lo reproduce en el dispositivo de salida.
final class AppVolumeTap {
    enum TapError: Error, CustomStringConvertible {
        case noOutputDevice
        case createTap(OSStatus)
        case unsupportedFormat
        case createAggregate(OSStatus)
        case createIOProc(OSStatus)
        case start(OSStatus)

        var description: String {
            switch self {
            case .noOutputDevice: "no hay dispositivo de salida"
            case .createTap(let s): "no se pudo crear el tap (\(s))"
            case .unsupportedFormat: "formato de audio no soportado"
            case .createAggregate(let s): "no se pudo crear el dispositivo agregado (\(s))"
            case .createIOProc(let s): "no se pudo crear el IOProc (\(s))"
            case .start(let s): "no se pudo iniciar el audio (\(s))"
            }
        }
    }

    private let gain: GainBox
    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?

    var volume: Float {
        get { gain.value }
        set { gain.value = newValue }
    }

    init(process: AudioObjectID, outputDevice: AudioObjectID, volume: Float) throws {
        gain = GainBox(volume)

        guard let outputUID = outputDevice.readString(kAudioDevicePropertyDeviceUID) else {
            throw TapError.noOutputDevice
        }

        // 1. Crear el tap: captura el audio del proceso y silencia su salida normal
        let description = CATapDescription(stereoMixdownOfProcesses: [process])
        description.uuid = UUID()
        description.name = "SoundMaster Tap"
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw TapError.createTap(status) }

        // 2. Revisar el formato del tap: esperamos Float32 PCM
        let format: AudioStreamBasicDescription = tapID.read(kAudioTapPropertyFormat,
                                                             default: AudioStreamBasicDescription())
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else {
            invalidate()
            throw TapError.unsupportedFormat
        }
        let tapChannels = Int(format.mChannelsPerFrame)

        // 3. Dispositivo agregado privado: entrada = tap, salida = tus bocinas
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SoundMaster Aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else {
            invalidate()
            throw TapError.createAggregate(status)
        }

        // 4. IOProc: se ejecuta en el hilo de tiempo real cada pocos milisegundos
        let gain = self.gain
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, input, _, output, _ in
            AppVolumeTap.render(input: input, output: output, tapChannels: tapChannels, gain: gain.value)
        }
        guard status == noErr else {
            invalidate()
            throw TapError.createIOProc(status)
        }

        // 5. Arrancar
        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            invalidate()
            throw TapError.start(status)
        }
    }

    deinit { invalidate() }

    /// Detiene y destruye todo. Si no se hace, la app quedaría silenciada.
    func invalidate() {
        if aggregateID != .unknown, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != .unknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = .unknown
        }
        if tapID != .unknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = .unknown
        }
    }

    // MARK: - Hilo de audio (sin print, sin reservar memoria, sin locks)

    private struct Source {
        let samples: UnsafeMutablePointer<Float>
        let stride: Int   // canales intercalados en ese buffer
        let frames: Int
    }

    /// Encuentra el canal número `channel` dentro de la lista de buffers de entrada.
    private static func source(in buffers: UnsafeMutableAudioBufferListPointer, channel: Int) -> Source? {
        var base = 0
        for buffer in buffers {
            let count = Int(buffer.mNumberChannels)
            if channel < base + count {
                guard count > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return nil }
                let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * count)
                return Source(samples: data + (channel - base), stride: count, frames: frames)
            }
            base += count
        }
        return nil
    }

    private static func render(input: UnsafePointer<AudioBufferList>,
                               output: UnsafeMutablePointer<AudioBufferList>,
                               tapChannels: Int,
                               gain: Float) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)

        // Los canales del tap son los ÚLTIMOS de la entrada
        // (antes pueden venir micrófonos del dispositivo de salida).
        var totalInput = 0
        for buffer in inputs { totalInput += Int(buffer.mNumberChannels) }
        let tapStart = max(0, totalInput - tapChannels)
        let available = totalInput - tapStart

        var outputChannel = 0
        for buffer in outputs {
            let channels = Int(buffer.mNumberChannels)
            defer { outputChannel += channels }
            guard channels > 0, let dst = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)

            for c in 0..<channels {
                var copied = 0
                if available > 0,
                   let src = source(in: inputs, channel: tapStart + (outputChannel + c) % available) {
                    copied = min(frames, src.frames)
                    for f in 0..<copied {
                        let sample = src.samples[f * src.stride] * gain
                        dst[f * channels + c] = min(1, max(-1, sample))   // evita distorsión al amplificar
                    }
                }
                for f in copied..<frames { dst[f * channels + c] = 0 }
            }
        }
    }
}
