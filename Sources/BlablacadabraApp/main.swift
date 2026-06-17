import AppKit

// NSApplicationMain by hand; the AppKit main thread is the main actor.
//
// `NSApplication.delegate` is `weak(unsafe)`, so it does NOT keep the delegate
// alive. Hold a strong, process-lifetime reference here so the delegate can't
// deallocate out from under AppKit (e.g. if `run()` ever returns), which would
// leave a dangling pointer and crash on the next delegate callback.
var appDelegate: AnyObject?

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    appDelegate = delegate
    app.delegate = delegate
    app.run()
}
