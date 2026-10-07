// A fork of LaunchAtLogin-Modern by Sindre Sorhus (https://github.com/sindresorhus/LaunchAtLogin-Modern), MIT
// licensed: see LICENSE.

#if os(macOS)
    import AppKit
    import Combine
    import os
    import ServiceManagement
    import SwiftUI

    /// Launch at login for the main app, through `SMAppService.mainApp`.
    ///
    /// Same API as LaunchAtLogin-Modern, but the status is cached. Every `SMAppService.status` read is a synchronous
    /// round trip to the login items daemon, which validates the app's signature each time, and a SwiftUI `Toggle`
    /// reads its binding many times while a window is built, laid out and made key. Reading the status there blocked the
    /// main thread for most of the time a settings window took to open. Here it's read once, then again off the main
    /// thread after every change, and when the app becomes active (the user may have changed it in System Settings
    /// meanwhile): right away while a view shows it, otherwise when one next asks. Views only ever see the cached value.
    public enum LaunchAtLogin {
        /// Turns launch at login on or off, or tells whether it's on. Reading never blocks once the status has been read
        /// once. Setting updates the value right away and registers or unregisters off the main thread, after which the
        /// value settles on what macOS reports.
        public static var isEnabled: Bool {
            get { status == .enabled }
            set { setEnabled(newValue, fromControl: false) }
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
            let (cached, activation) = state.withLock { state -> (SMAppService.Status?, Int) in
                guard let status = state.status else { return (nil, state.activations) }
                if Thread.isMainThread {
                    rereadIfStale(&state)
                    return (status, state.activations)
                }
                return (state.pendingChanges > 0 || now - state.readAt < 1 ? status : nil, state.activations)
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
                store(read, readSince: activation, in: &state)
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
            let start = state.withLock { state -> Bool in
                guard !state.refreshing else { return false }
                state.refreshing = true
                return true
            }
            if start {
                queue.async { reread() }
            }
        }

        /// A view started or stopped observing `observable`: SwiftUI subscribes to it while the view is on screen.
        static func watching(_ started: Bool) {
            state.withLock { state in
                state.watchers = max(0, state.watchers + (started ? 1 : -1))
                if started {
                    rereadIfStale(&state)
                }
            }
        }

        /// From a read on the main thread: a status marked stale is read again in the background, once.
        static func rereadIfStale() {
            state.withLock { rereadIfStale(&$0) }
        }

        private static func rereadIfStale(_ state: inout State) {
            guard state.stale, !state.refreshing, state.pendingChanges == 0, state.status != nil else { return }
            state.refreshing = true
            queue.async { reread() }
        }

        private struct State {
            var status: SMAppService.Status?
            /// `systemUptime` of the read behind `status`.
            var readAt: TimeInterval = 0
            /// Changes waiting on `queue`: a read that lands meanwhile would show the old status, so it's skipped.
            var pendingChanges = 0
            var observing = false
            /// The app became active since the last read finished.
            var stale = false
            var refreshing = false
            /// Times the app became active, so a read knows whether one happened while it ran.
            var activations = 0
            /// Views observing `observable`, which get a fresh status as soon as the app becomes active.
            var watchers = 0
        }

        /// Under the app's own subsystem, so its logs show a failed change.
        private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LaunchAtLogin", category: "LaunchAtLogin")
        private static let state = OSAllocatedUnfairLock(initialState: State())
        /// Serial, so changes reach the daemon in the order they were made, and reads never overtake them.
        private static let queue = DispatchQueue(label: "com.lowtechguys.LaunchAtLogin", qos: .userInitiated)

        /// Runs on `queue`.
        private static func reread() {
            let activation = state.withLock { $0.activations }
            let status = SMAppService.mainApp.status
            let (current, again) = state.withLock { state -> (Bool, Bool) in
                state.refreshing = false
                guard state.pendingChanges == 0 else { return (false, false) }
                store(status, readSince: activation, in: &state)
                return (true, readAgainIfWatched(&state))
            }
            if current {
                publish()
            }
            if again {
                queue.async { reread() }
            }
        }

        /// Keeps a read, and clears the stale mark only when the app didn't become active again while it ran: the change
        /// that brought the user back may be newer than the read.
        private static func store(_ status: SMAppService.Status, readSince activation: Int, in state: inout State) {
            state.status = status
            state.readAt = ProcessInfo.processInfo.systemUptime
            if state.activations == activation {
                state.stale = false
            }
        }

        /// Still stale after a read, with a view showing the status: one more read.
        private static func readAgainIfWatched(_ state: inout State) -> Bool {
            guard state.stale, state.watchers > 0, !state.refreshing else { return false }
            state.refreshing = true
            return true
        }

        /// `fromControl` when the user flipped a control: only then can System Settings open for an approval, never for a
        /// change a script or an agent made.
        static func setEnabled(_ enabled: Bool, fromControl: Bool) {
            startObserving()
            // Shown at once; macOS has the last word after the change.
            let shown: SMAppService.Status = enabled ? .enabled : .notRegistered
            state.withLock {
                $0.status = shown
                $0.pendingChanges += 1
            }
            publish()

            queue.async {
                let activation = state.withLock { $0.activations }
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
                let (last, again) = state.withLock { state -> (Bool, Bool) in
                    state.pendingChanges -= 1
                    guard state.pendingChanges == 0 else { return (false, false) }
                    store(status, readSince: activation, in: &state)
                    return (true, readAgainIfWatched(&state))
                }
                guard last else { return }
                if again {
                    queue.async { reread() }
                }
                publish()
                // Turned off in System Settings before: registering can't undo that, the user has to.
                if enabled, fromControl, status == .requiresApproval {
                    DispatchQueue.main.async { SMAppService.openSystemSettingsLoginItems() }
                }
            }
        }

        /// Shows views the cached status as it is when the main thread gets to it, so updates that land out of order
        /// still end on the latest. Never inline: a first read can happen while SwiftUI is updating a view, which must not
        /// publish changes.
        private static func publish() {
            Task { @MainActor in
                observable.cached = state.withLock { $0.status }
            }
        }

        /// The app coming back to the front is when a change made in System Settings shows up.
        private static func startObserving() {
            guard state.withLock({ state -> Bool in
                defer { state.observing = true }
                return !state.observing
            }) else { return }
            // Each read is a daemon lookup, and some apps become active often: read now only while a view shows the status,
            // otherwise when one next asks for it.
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
                let now = state.withLock { state -> Bool in
                    state.activations += 1
                    state.stale = true
                    guard state.watchers > 0, !state.refreshing else { return false }
                    state.refreshing = true
                    return true
                }
                if now {
                    queue.async { reread() }
                }
            }
        }
    }

    public extension LaunchAtLogin {
        /// Launch at login for views that bind to it some other way than `LaunchAtLogin.Toggle`, redrawn when the status
        /// changes:
        ///
        /// ```
        /// @ObservedObject private var launchAtLogin = LaunchAtLogin.observable
        ///
        /// MyToggle("Start at login", isOn: $launchAtLogin.isEnabled)
        /// ```
        @MainActor
        final class Observable: ObservableObject {
            public var isEnabled: Bool {
                get { status == .enabled }
                set {
                    // A tap shows at once: setting a binding is a user action, never a view update, so it can publish.
                    cached = newValue ? .enabled : .notRegistered
                    LaunchAtLogin.setEnabled(newValue, fromControl: true)
                }
            }

            public var status: SMAppService.Status {
                guard let cached else { return LaunchAtLogin.status }
                LaunchAtLogin.rereadIfStale()
                return cached
            }

            /// Counts the views subscribed to it, so the app becoming active reads the status again right away only when
            /// a view shows it, whatever control the view draws it with.
            public nonisolated let objectWillChange = WillChange()

            /// Published only when it changes, so a re-read that finds the same status redraws nothing.
            var cached: SMAppService.Status? {
                willSet {
                    if newValue != cached {
                        objectWillChange.send()
                    }
                }
            }
        }

        /// `Observable`'s change publisher, which tells `LaunchAtLogin` when views start and stop observing it.
        struct WillChange: Publisher, @unchecked Sendable {
            public typealias Output = Void
            public typealias Failure = Never

            public func receive<S: Subscriber>(subscriber: S) where S.Input == Void, S.Failure == Never {
                LaunchAtLogin.watching(true)
                subject
                    .handleEvents(receiveCancel: { LaunchAtLogin.watching(false) })
                    .receive(subscriber: subscriber)
            }

            func send() {
                subject.send()
            }

            private let subject = PassthroughSubject<Void, Never>()
        }

        @MainActor static let observable = Observable()
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
                SwiftUI.Toggle(isOn: $launchAtLogin.isEnabled) { label }
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
