import AVFoundation
import OSLog

/// Writes PCM audio samples to an AAC-LC (.m4a) file using AVAssetWriter.
final class ChunkWriter {
    private let logger = Logger(subsystem: "com.example.recall", category: "ChunkWriter")
    private let outputURL: URL
    private let sampleRate: Int
    private let bitRate: Int

    private var assetWriter: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor? // unused; kept for clarity
    private var currentSampleTime: CMTime = .zero
    private var startTime: CMTime?
    private var isFinished = false

    init(outputURL: URL, sampleRate: Int = 16_000, bitRate: Int = 48_000) {
        self.outputURL = outputURL
        self.sampleRate = sampleRate
        self.bitRate = bitRate
    }

    /// Begin the asset writer session.
    func start() throws {
        // Remove existing file if any
        try? FileManager.default.removeItem(at: outputURL)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]

        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw ChunkWriterError.cannotAddInput
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw ChunkWriterError.startWritingFailed(writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        self.assetWriter = writer
        self.writerInput = input
        self.currentSampleTime = .zero
        self.startTime = nil
        self.isFinished = false

        logger.info("ChunkWriter started: \(self.outputURL.lastPathComponent)")
    }

    /// Append PCM Float32 samples. Converts to a CMSampleBuffer internally.
    func appendSamples(_ samples: [Float], at time: CMTime) {
        guard let input = writerInput, !isFinished else { return }
        guard input.isReadyForMoreMediaData else {
            logger.debug("Writer input not ready, dropping \(samples.count) samples")
            return
        }

        if startTime == nil {
            startTime = time
        }

        guard let sampleBuffer = createSampleBuffer(from: samples, at: time) else {
            logger.error("Failed to create sample buffer")
            return
        }

        input.append(sampleBuffer)
        let frameDuration = CMTime(value: CMTimeValue(samples.count), timescale: CMTimeScale(sampleRate))
        currentSampleTime = CMTimeAdd(time, frameDuration)
    }

    /// Finalize the file and return duration + file size.
    func finish() async -> (duration: TimeInterval, fileSize: Int64) {
        guard let writer = assetWriter, !isFinished else {
            return (0, 0)
        }
        isFinished = true

        writerInput?.markAsFinished()

        // Timeout-guarded finish: prevents hang if finishWriting callback never fires
        let onceResumer = OnceResumer()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            onceResumer.setContinuation(continuation)

            writer.finishWriting {
                onceResumer.resume()
            }

            // 5-second timeout: cancel writing and force-resume if callback is stuck
            DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) {
                guard onceResumer.resume() else { return }
                writer.cancelWriting()
                self.logger.error("ChunkWriter.finish() timed out after 5s — cancelled writing")
            }
        }

        let duration: TimeInterval
        if let start = startTime {
            duration = CMTimeGetSeconds(CMTimeSubtract(currentSampleTime, start))
        } else {
            duration = 0
        }

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

    // MARK: - Private

    private func createSampleBuffer(from samples: [Float], at time: CMTime) -> CMSampleBuffer? {
        let frameCount = samples.count

        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var formatDescription: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let desc = formatDescription else { return nil }

        var sampleBuffer: CMSampleBuffer?

        let dataByteSize = frameCount * MemoryLayout<Float>.size
        let blockBuffer: CMBlockBuffer? = samples.withUnsafeBytes { rawBuf in
            guard let baseAddress = rawBuf.baseAddress else { return nil }
            var block: CMBlockBuffer?
            let createStatus = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: dataByteSize,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: dataByteSize,
                flags: 0,
                blockBufferOut: &block
            )
            guard createStatus == kCMBlockBufferNoErr, let b = block else { return nil }
            let replaceStatus = CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: b,
                offsetIntoDestination: 0,
                dataLength: dataByteSize
            )
            guard replaceStatus == kCMBlockBufferNoErr else { return nil }
            return b
        }

        guard let block = blockBuffer else { return nil }

        let createBufferStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: desc,
            sampleCount: frameCount,
            presentationTimeStamp: time,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard createBufferStatus == noErr else { return nil }

        return sampleBuffer
    }

    // MARK: - Errors

    // MARK: - OnceResumer (thread-safe single-resume guard)

    /// Ensures a CheckedContinuation is resumed exactly once, even with concurrent callers.
    private final class OnceResumer: @unchecked Sendable {
        private var continuation: CheckedContinuation<Void, Never>?
        private let lock = NSLock()

        func setContinuation(_ c: CheckedContinuation<Void, Never>) {
            lock.lock()
            continuation = c
            lock.unlock()
        }

        /// Returns `true` if this call actually resumed, `false` if already resumed.
        @discardableResult
        func resume() -> Bool {
            lock.lock()
            let cont = continuation
            continuation = nil
            lock.unlock()
            guard let cont else { return false }
            cont.resume()
            return true
        }
    }

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
