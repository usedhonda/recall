import Foundation

/// Capture times for an audio original, derived from clock readings the engine took
/// while recording. Nothing here is measured at the microphone: the chunk's clock reading
/// is taken when the writer starts, the first sample sits `preRollSamples` before it, and
/// the last sample was appended at the last write tick. A chunk assembled from a held
/// short chunk has no reconstructable interval and gets no capture at all.
enum AudioCaptureEvidence {
    static let startMethod = "recall.chunk-clock-minus-preroll"
    static let endMethod = "recall.last-write-tick-clock"
    static let methodVersion = "1"
    /// An estimate (write-tick jitter plus input latency), not yet measured on a device.
    static let precisionMs = 300

    struct Result {
        /// Extra `source_payload` entries naming the inputs, as strings like the rest.
        let sourceFields: [String: String]
        /// `metadata.capture`
        let capture: [String: Any]
    }

    static func make(externalID: String, clockAtChunkStart: Date?, preRollSamples: Int?,
                     lastWriteAt: Date?, sampleRate: Int) -> Result? {
        guard let clockAtChunkStart, let preRollSamples, let lastWriteAt,
              preRollSamples >= 0, sampleRate > 0 else { return nil }
        let start = clockAtChunkStart.addingTimeInterval(-Double(preRollSamples) / Double(sampleRate))
        guard start <= lastWriteAt else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fields = [
            "capture_clock_at_chunk_start": formatter.string(from: clockAtChunkStart),
            "capture_pre_roll_samples": String(preRollSamples),
            "capture_last_write_utc": formatter.string(from: lastWriteAt)
        ]
        func evidence(_ method: String, _ names: [String]) -> [String: Any] {
            ["basis": "derived",
             "source_refs": [["source": "recall", "external_id": externalID]],
             "source_fields": names, "method": method,
             "method_version": methodVersion, "precision_ms": precisionMs]
        }
        let capture: [String: Any] = [
            "start": formatter.string(from: start), "end": formatter.string(from: lastWriteAt),
            "status": "known", "basis": "derived",
            "provenance": [
                "start": evidence(startMethod, ["capture_clock_at_chunk_start", "capture_pre_roll_samples"]),
                "end": evidence(endMethod, ["capture_last_write_utc"])
            ]
        ]
        return Result(sourceFields: fields, capture: capture)
    }
}
