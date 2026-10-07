# LaunchAtLogin

Launch at login for macOS apps, through `SMAppService`. A fork of [LaunchAtLogin-Modern](https://github.com/sindresorhus/LaunchAtLogin-Modern) with the same API that never makes the main thread wait on the login items daemon.

Every read of `SMAppService.mainApp.status` is a synchronous call to that daemon, which checks the app's code signature each time. LaunchAtLogin-Modern's toggle reads it from its binding, and SwiftUI reads a binding many times while it builds, lays out and shows a window, so a settings window with the toggle in it opened noticeably slower.

## What's different

- The status is read once and kept, then read again off the main thread after every change, and when the app becomes active: right away while a `LaunchAtLogin.Toggle` is on screen, otherwise the next time a view asks for it
- Reading `isEnabled` or `status` off the main thread, where waiting costs no frames, reads it again when the kept status is more than a second old
- Setting `isEnabled` shows the new value at once, and registers or unregisters off the main thread
- `status` gives the whole `SMAppService.Status`, and `refresh()` reads it again
- When the user turned the login item off in System Settings, turning it back on with the toggle opens System Settings on Login Items, since only they can allow it there. Setting `isEnabled` from code never opens it

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

A view with its own control binds to `LaunchAtLogin.observable`, which redraws it when the status changes:

```swift
@ObservedObject private var launchAtLogin = LaunchAtLogin.observable

MyToggle("Start at login", isOn: $launchAtLogin.isEnabled)
```

A change that fails is logged under the app's bundle identifier, category `LaunchAtLogin`.

## Licence

MIT, see [LICENSE](LICENSE).
