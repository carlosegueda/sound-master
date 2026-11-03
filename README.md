# SoundMaster

SoundMaster is a lightweight macOS menu bar utility that provides independent volume control for each application currently producing audio. It is built natively in Swift and SwiftUI on top of the Core Audio process tap API introduced in recent versions of macOS, and requires no third-party audio drivers or kernel extensions.

## Features

- **Per-application volume control** — Adjust the volume of each active application individually, from 0% up to 150%.
- **Per-application mute** — Silence any application with a single click without affecting the rest of the system.
- **Master volume** — Control the system output volume directly from the mixer through the **Master** slider, when the active output device supports it.
- **Automatic application detection** — Applications appear in the mixer as soon as they begin playing audio. Multiple processes belonging to the same application are grouped into a single channel.
- **Persistent settings** — Volume and mute preferences are saved per application and restored automatically.
- **Output device awareness** — SoundMaster follows changes to the default output device and reapplies all settings transparently.
- **Zero overhead at unity gain** — Applications set to 100% are not intercepted, so their audio path remains untouched and introduces no additional latency.

## Requirements

- macOS 15.0 or later
- Permission to capture audio from other applications (requested on first use)

## Installation

1. Download `SoundMaster.zip` from the [Releases](../../releases) page and extract it.
2. Move `SoundMaster.app` to the `Applications` folder.
3. This build is not signed with an Apple Developer ID or notarized, so macOS will block it on first launch. Remove the quarantine attribute by running the following command in Terminal:

   ```sh
   xattr -dr com.apple.quarantine /Applications/SoundMaster.app
   ```

4. Launch SoundMaster. On first use, macOS will ask for permission to capture audio from other applications; this permission is required for per-application volume control.

SoundMaster runs exclusively in the menu bar and does not appear in the Dock. To quit, open the mixer and click **Quit** (⌘Q).

## Building from source

The Xcode project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project SoundMaster.xcodeproj -scheme SoundMaster -configuration Release -derivedDataPath build build
```

The application will be located at `build/Build/Products/Release/SoundMaster.app`. To package it for distribution:

```sh
ditto -c -k --keepParent build/Build/Products/Release/SoundMaster.app SoundMaster.zip
```

## How it works

For each application whose volume differs from 100%, SoundMaster creates a private Core Audio process tap that mutes the application's original output, captures its audio stream, applies the requested gain, and routes the result to the current output device through a private aggregate device. When an application is returned to 100%, no additional processing is applied to its audio.

## Known limitations

- The master volume control is hidden for output devices that do not expose a software-adjustable volume.
