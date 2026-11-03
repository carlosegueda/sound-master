import SwiftUI

@main
struct SoundMasterApp: App {
    @State private var store = MixerStore()

    var body: some Scene {
        // Ícono en la barra de menú → panel con el mezclador
        MenuBarExtra("SoundMaster", systemImage: "speaker.wave.2.fill") {
            MixerView()
                .environment(store)
        }
        .menuBarExtraStyle(.window)
    }
}
