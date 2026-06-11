import AVFoundation
import AppKit
import CoreGraphics

/// Permission state + onboarding logic for the two capture sources.
///
/// Screen Recording (needed for system audio) cannot be granted
/// programmatically: macOS shows its prompt once, and after a denial the user
/// must flip the toggle in System Settings themselves. This type gives the UI
/// layer everything it needs to walk the user through that.
public enum CapturePermissions {
    public enum ScreenRecordingStatus {
        /// Access granted; capture will work.
        case granted
        /// Not yet asked; calling `requestScreenRecordingAccess()` will show
        /// the system prompt.
        case notDetermined
        /// Asked and denied; only the user can fix it, in System Settings.
        case denied
    }

    // MARK: Screen Recording (system audio)

    public static var screenRecordingStatus: ScreenRecordingStatus {
        if CGPreflightScreenCaptureAccess() { return .granted }
        // CoreGraphics doesn't distinguish "never asked" from "denied"; track
        // whether we've triggered the prompt ourselves.
        return hasPromptedForScreenRecording ? .denied : .notDetermined
    }

    /// Triggers the one-time system prompt. Returns true if access is granted
    /// (immediately, or was already). After a denial this becomes a no-op and
    /// the user must use System Settings; send them there with
    /// `openScreenRecordingSettings()`.
    @discardableResult
    public static func requestScreenRecordingAccess() -> Bool {
        defer { hasPromptedForScreenRecording = true }
        return CGRequestScreenCaptureAccess()
    }

    /// Opens System Settings directly to Privacy & Security > Screen &
    /// System Audio Recording.
    public static func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    private static let promptedKey = "blablacadabra.promptedForScreenRecording"
    private static var hasPromptedForScreenRecording: Bool {
        get { UserDefaults.standard.bool(forKey: promptedKey) }
        set { UserDefaults.standard.set(newValue, forKey: promptedKey) }
    }

    // MARK: Microphone (optional mic source)

    public static var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Shows the mic permission prompt if not yet determined; resolves with
    /// the final answer.
    public static func requestMicrophoneAccess() async -> Bool {
        switch microphoneStatus {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// Opens System Settings directly to Privacy & Security > Microphone.
    public static func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }
}
