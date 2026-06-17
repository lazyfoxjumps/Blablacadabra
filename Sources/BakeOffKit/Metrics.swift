import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Phase 7B (B.4) — bake-off metrics
//
// Three small, pure samplers the runner stitches together per (model, clip):
// token throughput, peak RAM, and the worst thermal state seen. Each is kept free of
// any model/IO so it can be unit-tested deterministically (the scaffold's
// `BakeOffMetricsTests`). The live readers (`currentResidentBytes`,
// `ProcessInfo.thermalState`) feed these; tests drive them with synthetic samples.

/// Accumulates generated-token counts against wall-clock time to yield tokens/sec.
/// Pure and deterministic: feed it `(tokens, seconds)` decode spans and read
/// `tokensPerSec`. Summing then dividing (rather than averaging per-line rates) keeps
/// long and short lines weighted by their actual token work.
public struct TokenThroughput: Sendable {
    public private(set) var totalTokens: Int = 0
    public private(set) var totalSeconds: Double = 0

    public init() {}

    /// Record one decode span: `tokens` generated over `seconds` of wall clock.
    /// Negative inputs (clock skew, bad counts) are ignored rather than corrupting the sum.
    public mutating func record(tokens: Int, seconds: Double) {
        guard tokens >= 0, seconds >= 0 else { return }
        totalTokens += tokens
        totalSeconds += seconds
    }

    /// Generated tokens per second across everything recorded; 0 when no time elapsed.
    public var tokensPerSec: Double {
        totalSeconds > 0 ? Double(totalTokens) / totalSeconds : 0
    }
}

/// Tracks the peak resident memory seen across a run. Monotonic non-decreasing by
/// construction — `record` only ever raises the peak — so a transient dip in RSS can
/// never lower the reported number.
public struct RAMPeakTracker: Sendable {
    public private(set) var peakBytes: UInt64 = 0

    public init() {}

    public mutating func record(_ bytes: UInt64) {
        peakBytes = max(peakBytes, bytes)
    }

    public var peakMB: Double {
        Double(peakBytes) / (1024 * 1024)
    }
}

/// Current task resident memory in bytes via `mach_task_basic_info`. The live runner
/// samples this after each line; tests drive `RAMPeakTracker` directly. Returns 0 if
/// the syscall fails (never traps the harness).
public func currentResidentBytes() -> UInt64 {
    #if canImport(Darwin)
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
    )
    let kr = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
        }
    }
    return kr == KERN_SUCCESS ? info.resident_size : 0
    #else
    return 0
    #endif
}

/// Tracks the worst `ProcessInfo.ThermalState` observed and whether it crossed the
/// `.fair` flag line (the scaffold's column flag for thermal pressure that could be
/// skewing latency). Thread-safe so a 1s background ticker and the per-line sampling
/// can both write. `ThermalState` isn't `Comparable`, so rank it explicitly.
public final class ThermalSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var _worst: ProcessInfo.ThermalState = .nominal

    public init() {}

    public func record(_ state: ProcessInfo.ThermalState) {
        lock.lock(); defer { lock.unlock() }
        if Self.rank(state) > Self.rank(_worst) { _worst = state }
    }

    /// Sample the live thermal state right now.
    public func sampleNow() {
        record(ProcessInfo.processInfo.thermalState)
    }

    public var worst: ProcessInfo.ThermalState {
        lock.lock(); defer { lock.unlock() }
        return _worst
    }

    /// True once the worst state reached `.fair` or beyond.
    public var flagged: Bool {
        Self.rank(worst) >= Self.rank(.fair)
    }

    /// Stable lowercase label for the JSON `thermal_state` column.
    public static func label(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func rank(_ s: ProcessInfo.ThermalState) -> Int {
        switch s {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        @unknown default: return 0
        }
    }
}
