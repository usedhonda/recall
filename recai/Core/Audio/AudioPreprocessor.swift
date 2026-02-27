import Accelerate
import Foundation

/// Lightweight audio preprocessing pipeline for STT optimization.
/// DC offset removal → High-pass filter (100Hz) → Peak limiter → Per-segment normalization.
struct AudioPreprocessor {

    private var biquad: vDSP.Biquad<Float>?

    init(sampleRate: Double = 16_000) {
        // 2nd-order Butterworth HPF at 100Hz
        let fc: Double = 100
        let w0 = 2.0 * .pi * fc / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / (2.0 * 0.7071) // Q = 1/√2

        let a0 = 1.0 + alpha
        let b0 = ((1.0 + cosW0) / 2.0) / a0
        let b1 = (-(1.0 + cosW0)) / a0
        let b2 = ((1.0 + cosW0) / 2.0) / a0
        let a1 = (-2.0 * cosW0) / a0
        let a2 = (1.0 - alpha) / a0

        let coeffs: [Double] = [b0, b1, b2, a1, a2]
        biquad = vDSP.Biquad(
            coefficients: coeffs,
            channelCount: 1,
            sectionCount: 1,
            ofType: Float.self
        )
    }

    // MARK: - Stream Processing (per-buffer, real-time safe)

    /// Apply DC removal + HPF + peak limiter to a buffer.
    mutating func process(_ samples: inout [Float]) {
        guard !samples.isEmpty else { return }
        removeDCOffset(&samples)
        applyHighPass(&samples)
        Self.applyPeakLimiter(&samples)
    }

    // MARK: - Segment Normalization (post-VAD, at chunk finalization)

    /// Normalize an entire segment to target RMS level.
    /// Call once on the complete buffered segment before AAC encoding.
    static func normalizeSegment(_ samples: inout [Float], targetRMSdB: Float = -20) {
        guard !samples.isEmpty else { return }

        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        guard rms > 1e-6 else { return }

        let currentDB = 20 * log10(rms)
        let gainDB = targetRMSdB - currentDB
        var gain = min(powf(10, gainDB / 20), 40.0) // cap at +32dB

        vDSP_vsmul(samples, 1, &gain, &samples, 1, vDSP_Length(samples.count))

        // Re-limit after gain
        applyPeakLimiter(&samples)
    }

    // MARK: - Private

    private func removeDCOffset(_ samples: inout [Float]) {
        var mean: Float = 0
        vDSP_meanv(samples, 1, &mean, vDSP_Length(samples.count))
        var neg = -mean
        vDSP_vsadd(samples, 1, &neg, &samples, 1, vDSP_Length(samples.count))
    }

    private mutating func applyHighPass(_ samples: inout [Float]) {
        guard var b = biquad else { return }
        samples = b.apply(input: samples)
        biquad = b
    }

    private static func applyPeakLimiter(_ samples: inout [Float]) {
        // -1dBFS ≈ 0.891
        var lo: Float = -0.891
        var hi: Float = 0.891
        vDSP_vclip(samples, 1, &lo, &hi, &samples, 1, vDSP_Length(samples.count))
    }
}
