# LaunchAtLogin

Launch at login for macOS apps, through `SMAppService`. A fork of [LaunchAtLogin-Modern](https://github.com/sindresorhus/LaunchAtLogin-Modern) with the same API that never makes the main thread wait on the login items daemon.

Every read of `SMAppService.mainApp.status` is a synchronous call to that daemon, which checks the app's code signature each time. LaunchAtLogin-Modern's toggle reads it from its binding, and SwiftUI reads a binding many times while it builds, lays out and shows a window, so a settings window with the toggle in it opened noticeably slower.

## What's different

- The status is read once and kept, then read again off the main thread when the app becomes active and after every change
- Setting `isEnabled` shows the new value at once, and registers or unregisters off the main thread
- `status` gives the whole `SMAppService.Status`, and `refresh()` reads it again
- When the user turned the login item off in System Settings, turning it back on opens System Settings on Login Items, since only they can allow it there

## Usage

```swift
.package(url: "https://github.com/FuzzyIdeas/LaunchAtLogin", from: "1.0.0")
```

```swift
import LaunchAtLogin

struct SettingsView: View {
    var body: some View {
        LaunchAtLogin.Toggle()
    }
}

LaunchAtLogin.isEnabled = true
```

`LaunchAtLogin.Toggle("Start at login")` and `LaunchAtLogin.Toggle { Text("Start at login") }` set another label.

## Licence

MIT, see [LICENSE](LICENSE).
