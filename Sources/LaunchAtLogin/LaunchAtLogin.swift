// A fork of LaunchAtLogin-Modern by Sindre Sorhus (https://github.com/sindresorhus/LaunchAtLogin-Modern), MIT
// licensed: see LICENSE.

#if os(macOS)
    import AppKit
    import os
    import ServiceManagement
    import SwiftUI

    /// Launch at login for the main app, through `SMAppService.mainApp`.
    ///
    /// Same API as LaunchAtLogin-Modern, but the status is cached. Every `SMAppService.status` read is a synchronous
    /// round trip to the login items daemon, which validates the app's signature each time, and a SwiftUI `Toggle`
    /// reads its binding many times while a window is built, laid out and made key. Reading the status there blocked the
    /// main thread for most of the time a settings window took to open. Here it's read once, then again off the main
    /// thread when the app becomes active (the user may have changed it in System Settings meanwhile) and after every
    /// change, and views only ever see the cached value.
    public enum LaunchAtLogin {
        /// Turns launch at login on or off, or tells whether it's on. Reading never blocks once the status has been read
        /// once. Setting updates the value right away and registers or unregisters off the main thread, after which the
        /// value settles on what macOS reports.
        public static var isEnabled: Bool {
            get { status == .enabled }
            set { setEnabled(newValue) }
        }

        /// The main app's login item status: `.requiresApproval` when the user turned it off in System Settings >
        /// General > Login Items, which only they can undo.
        ///
        /// On the main thread it's the status as last read. Off the main thread, where waiting costs no frames, a status
        /// read more than a second ago is read again, so code answering a script or an agent while the app sits in the
        /// background sees a change made in System Settings.
        public static var status: SMAppService.Status {
            startObserving()
            let now = ProcessInfo.processInfo.systemUptime
            let cached = state.withLock { state -> SMAppService.Status? in
                guard let status = state.status else { return nil }
                return Thread.isMainThread || state.pendingChanges > 0 || now - state.readAt < 1 ? status : nil
            }
            if let cached {
                return cached
            }
            // Nothing read yet, or a stale read off the main thread. On the main thread this happens once, so the first
            // answer is the real one rather than a guess that a toggle would visibly flip from.
            let read = SMAppService.mainApp.status
            let status = state.withLock { state -> SMAppService.Status in
                // A change made meanwhile wins: the read may predate it.
                if state.pendingChanges > 0, let status = state.status {
                    return status
                }
                state.status = read
                state.readAt = ProcessInfo.processInfo.systemUptime
                return read
            }
            publish()
            return status
        }

        /// Whether the app was launched at login.
        ///
        /// - Important: This property must only be checked in `NSApplicationDelegate#applicationDidFinishLaunching`.
        public static var wasLaunchedAtLogin: Bool {
            let event = NSAppleEventManager.shared().currentAppleEvent
            return event?.eventID == kAEOpenApplication
                && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        }

        /// Reads the status again off the main thread, and updates `isEnabled`, `status` and any `Toggle` with it.
        /// Call it early at launch so the first view to ask already has the answer.
        public static func refresh() {
            startObserving()
            queue.async { reread() }
        }

        private struct State {
            var status: SMAppService.Status?
            /// `systemUptime` of the read behind `status`.
            var readAt: TimeInterval = 0
            /// Changes waiting on `queue`: a read that lands meanwhile would show the old status, so it's skipped.
            var pendingChanges = 0
            var observing = false
        }

        private static let logger = Logger(subsystem: "com.lowtechguys.LaunchAtLogin", category: "main")
        private static let state = OSAllocatedUnfairLock(initialState: State())
        /// Serial, so changes reach the daemon in the order they were made, and reads never overtake them.
        private static let queue = DispatchQueue(label: "com.lowtechguys.LaunchAtLogin", qos: .userInitiated)

        /// Runs on `queue`.
        private static func reread() {
            let status = SMAppService.mainApp.status
            let current = state.withLock { state -> Bool in
                guard state.pendingChanges == 0 else { return false }
                state.status = status
                state.readAt = ProcessInfo.processInfo.systemUptime
                return true
            }
            if current {
                publish()
            }
        }

        private static func setEnabled(_ enabled: Bool) {
            startObserving()
            // Shown at once; macOS has the last word after the change.
            let shown: SMAppService.Status = enabled ? .enabled : .notRegistered
            state.withLock {
                $0.status = shown
                $0.pendingChanges += 1
            }
            publish()

            queue.async {
                let service = SMAppService.mainApp
                do {
                    if enabled {
                        // Registered already: register again, which points the login item at this copy of the app if it
                        // moved.
                        if service.status == .enabled {
                            try? service.unregister()
                        }
                        try service.register()
                    } else {
                        try service.unregister()
                    }
                } catch {
                    logger.error("Failed to \(enabled ? "enable" : "disable") launch at login: \(error.localizedDescription)")
                }

                let status = service.status
                let last = state.withLock { state -> Bool in
                    state.pendingChanges -= 1
                    guard state.pendingChanges == 0 else { return false }
                    state.status = status
                    state.readAt = ProcessInfo.processInfo.systemUptime
                    return true
                }
                guard last else { return }
                publish()
                // Turned off in System Settings before: registering can't undo that, the user has to.
                if enabled, status == .requiresApproval {
                    DispatchQueue.main.async { SMAppService.openSystemSettingsLoginItems() }
                }
            }
        }

        /// Shows views the cached status as it is when the main thread gets to it, so updates that land out of order
        /// still end on the latest. Never inline: a first read can happen while SwiftUI is updating a view, which must not
        /// publish changes.
        private static func publish() {
            Task { @MainActor in
                observable.status = state.withLock { $0.status }
            }
        }

        /// The app coming back to the front is when a change made in System Settings shows up.
        private static func startObserving() {
            guard state.withLock({ state -> Bool in
                defer { state.observing = true }
                return !state.observing
            }) else { return }
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
                queue.async { reread() }
            }
        }
    }

    extension LaunchAtLogin {
        @MainActor
        final class Observable: ObservableObject {
            /// Published only when it changes, so a re-read that finds the same status redraws nothing.
            var status: SMAppService.Status? {
                willSet {
                    if newValue != status {
                        objectWillChange.send()
                    }
                }
            }
        }

        @MainActor fileprivate static let observable = Observable()
    }

    public extension LaunchAtLogin {
        /// A `Toggle` for launch at login, with its binding and label set up. It reads the cached status, so building and
        /// drawing it never waits on the login items daemon.
        ///
        /// ```
        /// struct ContentView: View {
        ///     var body: some View {
        ///         LaunchAtLogin.Toggle()
        ///     }
        /// }
        /// ```
        ///
        /// The default label is `"Launch at login"`, and another one can be passed in:
        ///
        /// ```
        /// LaunchAtLogin.Toggle {
        ///     Text("Start at login")
        /// }
        /// ```
        struct Toggle<Label: View>: View {
            /// Creates a toggle that displays a custom label.
            ///
            /// - Parameters:
            ///   - label: A view that describes the purpose of the toggle.
            public init(@ViewBuilder label: () -> Label) {
                self.label = label()
            }

            public var body: some View {
                SwiftUI.Toggle(isOn: Binding(
                    get: { (launchAtLogin.status ?? LaunchAtLogin.status) == .enabled },
                    set: { LaunchAtLogin.isEnabled = $0 }
                )) { label }
            }

            @ObservedObject private var launchAtLogin = LaunchAtLogin.observable
            private let label: Label
        }
    }

    public extension LaunchAtLogin.Toggle<Text> {
        /// Creates a toggle that generates its label from a localized string key.
        ///
        /// - Parameters:
        ///   - titleKey: The key for the toggle's localized title, that describes the purpose of the toggle.
        init(_ titleKey: LocalizedStringKey) {
            label = Text(titleKey)
        }

        /// Creates a toggle that generates its label from a string.
        ///
        /// - Parameters:
        ///   - title: A string that describes the purpose of the toggle.
        init(_ title: some StringProtocol) {
            label = Text(title)
        }

        /// Creates a toggle with the default title of `Launch at login`.
        init() {
            self.init("Launch at login")
        }
    }
#endif
