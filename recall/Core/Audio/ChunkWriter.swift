import AVFoundation
import OSLog

/// Writes PCM audio samples to an Opus (.caf) file using AVAudioFile.
final class ChunkWriter {
    private let logger = Logger(subsystem: "com.example.recall", category: "ChunkWriter")
    private let outputURL: URL
    private let sampleRate: Int
    private let bitRate: Int

    private var audioFile: AVAudioFile?
    private let inputFormat: AVAudioFormat
    private var samplesWritten: Int = 0
    private var isFinished = false

    init(outputURL: URL, sampleRate: Int = 16_000, bitRate: Int = 48_000) {
        self.outputURL = outputURL
        self.sampleRate = sampleRate
        self.bitRate = bitRate
        self.inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        )!
    }

    /// Begin writing to the output file.
    func start() throws {
        // Remove existing file if any
        try? FileManager.default.removeItem(at: outputURL)

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatOpus,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate
        ]

        let file = try AVAudioFile(
            forWriting: outputURL,
            settings: outputSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        self.audioFile = file
        self.samplesWritten = 0
        self.isFinished = false

        logger.info("ChunkWriter started: \(self.outputURL.lastPathComponent) (Opus \(self.bitRate/1000)kbps)")
    }

    /// Append PCM Float32 samples.
    func appendSamples(_ samples: [Float], at time: CMTime) {
        guard let file = audioFile, !isFinished else { return }

        let frameCount = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
            logger.error("Failed to create PCM buffer")
            return
        }

        buffer.frameLength = frameCount
        if let channelData = buffer.floatChannelData {
            samples.withUnsafeBufferPointer { src in
                channelData[0].update(from: src.baseAddress!, count: samples.count)
            }
        }

        do {
            try file.write(from: buffer)
            samplesWritten += samples.count
        } catch {
            logger.error("Failed to write samples: \(error.localizedDescription)")
        }
    }

    /// Finalize the file and return duration + file size.
    func finish() async -> (duration: TimeInterval, fileSize: Int64) {
        guard audioFile != nil, !isFinished else {
            return (0, 0)
        }
        isFinished = true

        // AVAudioFile finalizes on dealloc — release the reference
        audioFile = nil

        let duration = Double(samplesWritten) / Double(sampleRate)

        let fileSize: Int64
        if let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
           let size = attrs[.size] as? Int64 {
            fileSize = size
        } else {
            fileSize = 0
        }

        logger.info("ChunkWriter finished: \(self.outputURL.lastPathComponent), duration: \(duration, format: .fixed(precision: 1))s, size: \(fileSize) bytes")

        return (duration, fileSize)
    }

    // MARK: - Errors

    enum ChunkWriterError: Error, LocalizedError {
        case cannotAddInput
        case startWritingFailed(Error?)

        var errorDescription: String? {
            switch self {
            case .cannotAddInput:
                return "Cannot add audio input to asset writer"
            case .startWritingFailed(let error):
                return "Asset writer failed to start: \(error?.localizedDescription ?? "unknown")"
            }
        }
    }
}
