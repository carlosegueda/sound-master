import AudioToolbox
import CoreAudio
import Foundation

/// Box shared between the UI and the audio thread. Reading/writing a Float is safe here.
final class GainBox: @unchecked Sendable {
    var value: Float
    init(_ value: Float) { self.value = value }
}

/// Controls the volume of a SINGLE process:
/// mutes its original output, captures its audio, multiplies it by `volume`
/// and plays it back on the output device.
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
            case .noOutputDevice: "no output device available"
            case .createTap(let s): "could not create the process tap (\(s))"
            case .unsupportedFormat: "unsupported audio format"
            case .createAggregate(let s): "could not create the aggregate device (\(s))"
            case .createIOProc(let s): "could not create the IOProc (\(s))"
            case .start(let s): "could not start audio (\(s))"
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

        // 1. Create the tap: captures the process audio and mutes its normal output
        let description = CATapDescription(stereoMixdownOfProcesses: [process])
        description.uuid = UUID()
        description.name = "SoundMaster Tap"
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw TapError.createTap(status) }

        // 2. Check the tap format: Float32 PCM is expected
        let format: AudioStreamBasicDescription = tapID.read(kAudioTapPropertyFormat,
                                                             default: AudioStreamBasicDescription())
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else {
            invalidate()
            throw TapError.unsupportedFormat
        }
        let tapChannels = Int(format.mChannelsPerFrame)

        // 3. Private aggregate device: input = tap, output = speakers
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

        // 4. IOProc: runs on the real-time thread every few milliseconds
        let gain = self.gain
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, input, _, output, _ in
            AppVolumeTap.render(input: input, output: output, tapChannels: tapChannels, gain: gain.value)
        }
        guard status == noErr else {
            invalidate()
            throw TapError.createIOProc(status)
        }

        // 5. Start
        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            invalidate()
            throw TapError.start(status)
        }
    }

    deinit { invalidate() }

    /// Stops and tears everything down. Otherwise the app would remain muted.
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

    // MARK: - Audio thread (no printing, no allocations, no locks)

    private struct Source {
        let samples: UnsafeMutablePointer<Float>
        let stride: Int   // interleaved channels in that buffer
        let frames: Int
    }

    /// Finds channel number `channel` within the input buffer list.
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

        // The tap channels are the LAST ones in the input
        // (microphones of the output device may come first).
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
                        dst[f * channels + c] = min(1, max(-1, sample))   // prevents clipping when boosting
                    }
                }
                for f in copied..<frames { dst[f * channels + c] = 0 }
            }
        }
    }
}
