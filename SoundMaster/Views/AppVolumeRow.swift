import SwiftUI

/// A row: icon, name, mute button, slider and percentage.
struct AppVolumeRow: View {
    @Environment(MixerStore.self) private var store
    let channel: MixerStore.AppChannel

    var body: some View {
        let muted = store.isMuted(channel.id)
        let volume = store.volume(for: channel.id)

        HStack(spacing: 10) {
            Image(nsImage: channel.icon)
                .resizable()
                .frame(width: 22, height: 22)

            Text(channel.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 90, alignment: .leading)

            Button {
                store.toggleMute(channel.id)
            } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(muted ? .red : .secondary)
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help(muted ? "Unmute" : "Mute")

            Slider(value: Binding(get: { store.volume(for: channel.id) },
                                  set: { store.setVolume($0, for: channel.id) }),
                   in: 0...1.5)
                .disabled(muted)

            Text("\(Int((volume * 100).rounded()))%")
                .monospacedDigit()
                .foregroundStyle(volume > 1 ? .orange : .secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .opacity(muted ? 0.6 : 1)
    }
}
