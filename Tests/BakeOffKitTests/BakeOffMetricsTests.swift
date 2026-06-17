import Foundation
import Testing
@testable import BakeOffKit

/// Phase 7B (B.4) — pure metric samplers. No model, no IO: deterministic by design.
@Suite struct BakeOffMetricsTests {

    // MARK: - TokenThroughput

    @Test func tokensPerSecComputesFromKnownStream() {
        var t = TokenThroughput()
        // 300 tokens over 2.0s total → 150 tok/s, weighting by token work not line count.
        t.record(tokens: 100, seconds: 0.5)
        t.record(tokens: 200, seconds: 1.5)
        #expect(t.totalTokens == 300)
        #expect(abs(t.tokensPerSec - 150.0) < 1e-9)
    }

    @Test func tokensPerSecIsZeroWithNoElapsedTime() {
        var t = TokenThroughput()
        #expect(t.tokensPerSec == 0)
        t.record(tokens: 50, seconds: 0)   // a "free" sample can't divide by zero
        #expect(t.tokensPerSec == 0)
    }

    @Test func throughputIgnoresNegativeSamples() {
        var t = TokenThroughput()
        t.record(tokens: -10, seconds: 1.0)
        t.record(tokens: 10, seconds: -1.0)
        #expect(t.totalTokens == 0)
        #expect(t.totalSeconds == 0)
    }

    // MARK: - RAMPeakTracker

    @Test func ramPeakIsMonotonic() {
        var ram = RAMPeakTracker()
        ram.record(100 * 1024 * 1024)   // 100 MB
        ram.record(250 * 1024 * 1024)   // 250 MB — new peak
        ram.record(80 * 1024 * 1024)    // dip — must NOT lower the peak
        #expect(ram.peakBytes == 250 * 1024 * 1024)
        #expect(abs(ram.peakMB - 250.0) < 1e-9)
    }

    @Test func ramPeakStartsAtZero() {
        let ram = RAMPeakTracker()
        #expect(ram.peakBytes == 0)
        #expect(ram.peakMB == 0)
    }

    // MARK: - ThermalSampler

    @Test func thermalSamplerCaptures() {
        let thermal = ThermalSampler()
        #expect(thermal.flagged == false)          // nominal at rest
        thermal.record(.nominal)
        thermal.record(.fair)                       // crosses the flag line
        thermal.record(.nominal)                    // worst must stick
        #expect(thermal.worst == .fair)
        #expect(thermal.flagged == true)
        #expect(ThermalSampler.label(thermal.worst) == "fair")
    }

    @Test func thermalSamplerTracksWorstNotLast() {
        let thermal = ThermalSampler()
        thermal.record(.serious)
        thermal.record(.fair)
        #expect(thermal.worst == .serious)
        #expect(ThermalSampler.label(thermal.worst) == "serious")
    }
}
