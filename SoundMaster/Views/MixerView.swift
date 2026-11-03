import SwiftUI

/// The full mixer shown when clicking the menu bar icon.
struct MixerView: View {
    @Environment(MixerStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if store.hasMasterVolume {
                masterRow
            }

            Divider()

            if store.channels.isEmpty {
                Text("No apps are playing audio")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ForEach(store.channels) { channel in
                    AppVolumeRow(channel: channel)
                }
            }

            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Divider()
            footer
        }
        .padding(16)
        .frame(width: 380)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("SoundMaster").font(.headline)
            Label(store.outputName, systemImage: "hifispeaker.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var masterRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.wave.3.fill")
                .frame(width: 22)
            Text("Master")
                .fontWeight(.semibold)
                .frame(width: 118, alignment: .leading)
            Slider(value: Binding(get: { store.masterVolume },
                                  set: { store.setMasterVolume($0) }),
                   in: 0...1)
            Text("\(Int((store.masterVolume * 100).rounded()))%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
