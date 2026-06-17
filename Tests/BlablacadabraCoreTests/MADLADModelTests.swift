import Foundation
import Testing
@testable import BlablacadabraCore

/// Phase 7B (B.5) — T5 relative-position bucketing.
///
/// This is the one piece of MADLAD's architecture that's pure integer math AND easy to get
/// subtly wrong, so it's pinned directly (the rest of the forward pass is validated by the
/// real-weights bake-off). Expected values follow the canonical HF T5 `_relative_position_bucket`
/// with num_buckets=32, max_distance=128.
@Suite struct MADLADModelTests {

    private static func decoderBucket(_ rel: Int) -> Int {
        T5RelativeBucket.bucket(relative: rel, bidirectional: false, numBuckets: 32, maxDistance: 128)
    }

    private static func encoderBucket(_ rel: Int) -> Int {
        T5RelativeBucket.bucket(relative: rel, bidirectional: true, numBuckets: 32, maxDistance: 128)
    }

    // MARK: - Decoder (unidirectional): only the past contributes

    @Test func decoderExactSmallDistances() {
        #expect(Self.decoderBucket(0) == 0)     // same position
        #expect(Self.decoderBucket(-5) == 5)    // 5 tokens in the past
        #expect(Self.decoderBucket(-15) == 15)  // last of the exact range (maxExact=16)
    }

    @Test func decoderFutureCollapsesToZero() {
        // A decoder can't attend to the future; positive offsets clamp to bucket 0.
        #expect(Self.decoderBucket(3) == 0)
        #expect(Self.decoderBucket(50) == 0)
    }

    @Test func decoderLogRangeAndClamp() {
        #expect(Self.decoderBucket(-16) == 16)  // first log-spaced bucket
        #expect(Self.decoderBucket(-200) == 31) // clamped to numBuckets-1
    }

    // MARK: - Encoder (bidirectional): past and future split the budget

    @Test func encoderSplitsPastAndFuture() {
        // n halves to 16; future offsets get +16, past stay low.
        #expect(Self.encoderBucket(0) == 0)
        #expect(Self.encoderBucket(-1) == 1)    // 1 in the past
        #expect(Self.encoderBucket(1) == 17)    // 1 in the future (16 + 1)
        #expect(Self.encoderBucket(-7) == 7)
        #expect(Self.encoderBucket(7) == 23)    // 16 + 7
    }

    @Test func encoderClampsLongDistances() {
        #expect(Self.encoderBucket(-200) == 15) // far past, last past bucket
        #expect(Self.encoderBucket(200) == 31)  // far future, last bucket overall
    }

    // MARK: - Invariants

    @Test func allBucketsInRange() {
        for rel in -300...300 {
            let d = Self.decoderBucket(rel)
            let e = Self.encoderBucket(rel)
            #expect(d >= 0 && d < 32)
            #expect(e >= 0 && e < 32)
        }
    }
}
