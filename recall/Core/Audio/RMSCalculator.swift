import Accelerate

/// Stateless utility for computing RMS audio levels.
struct RMSCalculator {
    private init() {}

    /// Compute the root-mean-square level of audio samples using vDSP.
    static func rms(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return vDSP.rootMeanSquare(samples)
    }

    /// Compute the RMS level in decibels (dB).
    /// Returns -160 dB for silence (to avoid -infinity).
    static func rmsDB(of samples: [Float]) -> Float {
        let level = rms(of: samples)
        guard level > 0 else { return -160 }
        return 20 * log10(level)
    }
}
