import SwiftUI

@main
struct SoundMasterApp: App {
    @State private var store = MixerStore()

    var body: some Scene {
        // Menu bar icon → mixer panel
        MenuBarExtra("SoundMaster", systemImage: "speaker.wave.2.fill") {
            MixerView()
                .environment(store)
        }
        .menuBarExtraStyle(.window)
    }
}
