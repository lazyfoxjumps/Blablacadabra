import AppKit

// NSApplicationMain by hand; the AppKit main thread is the main actor.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
