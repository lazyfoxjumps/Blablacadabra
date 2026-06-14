import Foundation

/// Online speaker clustering by cosine similarity, kept pure (no model, no
/// I/O, value semantics) so the assignment logic is unit-testable on its own.
/// `SpeakerIdentifier` pairs it with FluidAudio's embedding extractor.
///
/// One embedding comes in per finalized utterance; `assign` decides which
/// speaker it belongs to:
/// - Closest existing cluster within `threshold` -> that speaker, and the
///   cluster's centroid drifts toward the new sample (a running mean, so a
///   voice's print stays current as the call goes on).
/// - No close-enough cluster and room left under the cap -> a brand-new
///   speaker, numbered in first-heard order (1-based).
/// - No close-enough cluster and the cap is full -> `.other`, the shared
///   overflow bucket. Overflow voices are never sub-clustered.
///
/// Embeddings are L2-normalized on the way in, so cosine similarity is just a
/// dot product and centroids stay on the unit sphere.
public struct SpeakerClusterer: Sendable {
    /// What `assignDetailed` reports: the label it chose plus the diagnostics
    /// behind that choice. `bestSimilarity` is the cosine to the nearest existing
    /// cluster (-1 when there were none yet); `createdNewCluster` is true when the
    /// utterance opened a fresh speaker. The actor logs these so a live call tells
    /// us the REAL same-voice/different-voice similarity spread on call audio
    /// (codec + noise), instead of us tuning `threshold` off the clean spike.
    public struct Assignment: Sendable, Equatable {
        public let id: SpeakerID
        public let bestSimilarity: Float
        public let createdNewCluster: Bool
    }

    /// How many distinct speakers get their own number before the rest collapse
    /// into `.other`.
    public let maxSpeakers: Int
    /// The number the FIRST cluster gets (1-based). Normally 1. In "Both" mode the
    /// mic lane is pinned to Speaker 1 (it's the user, by definition), so the
    /// system lane's clusterer starts at 2 — your own voice and the call's first
    /// voice never fight over S1.
    public let firstSpeakerNumber: Int
    /// Minimum cosine similarity to fold a new utterance into an existing
    /// cluster. Higher = stricter (more clusters); lower = more merging. The
    /// Step 1 spike measured same-voice similarity ~0.569 and different-voice
    /// ~0.399 for this model, so the gate has to sit BETWEEN those two clouds.
    /// 0.5 does: above 0.399 (two different people stay apart) but below 0.569
    /// (the same person merges instead of spawning a fresh color). An earlier
    /// 0.65 sat ABOVE the same-voice average, so one voice kept failing its own
    /// merge test and burned through a new color every utterance until it
    /// overflowed to `.other` (the live two-person over-clustering bug).
    public let threshold: Float

    /// L2-normalized centroid per active cluster; index + 1 is the speaker
    /// number. Capped at `maxSpeakers`.
    private var centroids: [[Float]] = []
    /// How many utterances have landed in each cluster, for the running-mean
    /// centroid update.
    private var counts: [Int] = []

    public init(maxSpeakers: Int = 4, threshold: Float = 0.5, firstSpeakerNumber: Int = 1) {
        self.maxSpeakers = max(1, maxSpeakers)
        self.threshold = threshold
        self.firstSpeakerNumber = max(1, firstSpeakerNumber)
    }

    /// Number of distinct speakers seen so far (excludes `.other`).
    public var speakerCount: Int { centroids.count }

    /// Assigns an embedding to a speaker, mutating the clusters in place.
    public mutating func assign(_ embedding: [Float]) -> SpeakerID {
        assignDetailed(embedding).id
    }

    /// Same as `assign` but also reports the nearest-cluster similarity and
    /// whether a new cluster was opened, so the caller can log the decision.
    public mutating func assignDetailed(_ embedding: [Float]) -> Assignment {
        let e = Self.l2(embedding)
        guard !e.isEmpty else { return Assignment(id: .other, bestSimilarity: -1, createdNewCluster: false) }

        // Declared single speaker for this lane (the user said how many people
        // are talking and there's exactly one here): collapse everything into one
        // cluster with NO similarity gate. Real call audio scatters one voice's
        // self-similarity ~0.35–0.86 — far too wide for any global threshold — so
        // when we KNOW there's one speaker we stop guessing and pin every
        // utterance to it. The centroid still drifts so it stays current.
        if maxSpeakers == 1 {
            let created = centroids.isEmpty
            let sim: Float
            if created {
                centroids.append(e)
                counts.append(1)
                sim = -1
            } else {
                sim = Self.cosine(e, centroids[0])
                counts[0] += 1
                let n = Float(counts[0])
                var merged = centroids[0]
                for k in 0..<merged.count { merged[k] += (e[k] - merged[k]) / n }
                centroids[0] = Self.l2(merged)
            }
            return Assignment(id: .speaker(firstSpeakerNumber), bestSimilarity: sim, createdNewCluster: created)
        }

        // Nearest existing cluster.
        var bestIndex = -1
        var bestSim: Float = -.infinity
        for (i, c) in centroids.enumerated() {
            let s = Self.cosine(e, c)
            if s > bestSim {
                bestSim = s
                bestIndex = i
            }
        }
        let reportedSim = centroids.isEmpty ? Float(-1) : bestSim

        if bestIndex >= 0, bestSim >= threshold {
            counts[bestIndex] += 1
            let n = Float(counts[bestIndex])
            var merged = centroids[bestIndex]
            for k in 0..<merged.count {
                merged[k] += (e[k] - merged[k]) / n // running mean toward the new sample
            }
            centroids[bestIndex] = Self.l2(merged)
            return Assignment(id: .speaker(firstSpeakerNumber + bestIndex), bestSimilarity: reportedSim, createdNewCluster: false)
        }

        // New voice: take the next number if there's room, else overflow.
        guard centroids.count < maxSpeakers else {
            return Assignment(id: .other, bestSimilarity: reportedSim, createdNewCluster: false)
        }
        centroids.append(e)
        counts.append(1)
        return Assignment(id: .speaker(firstSpeakerNumber + centroids.count - 1), bestSimilarity: reportedSim, createdNewCluster: true)
    }

    /// Forgets every cluster. Called between sessions so speaker numbers always
    /// start fresh at 1.
    public mutating func reset() {
        centroids.removeAll()
        counts.removeAll()
    }

    // MARK: - Vector math

    static func l2(_ v: [Float]) -> [Float] {
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? v.map { $0 / norm } : v
    }

    /// Dot product, which equals cosine similarity for L2-normalized inputs.
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        var sum: Float = 0
        for i in 0..<n { sum += a[i] * b[i] }
        return sum
    }
}
