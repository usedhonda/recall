import AVFoundation
import AudioToolbox
import Darwin

/// A synchronous Opus-in-CAF writer whose underlying file can never exceed `maxBytes`.
/// The byte limit is enforced in the AudioFile callbacks, including CAF headers and
/// packet-table rewrites performed while finalising the file.
final class BoundedCAFWriter {
    enum Error: Swift.Error, LocalizedError {
        case invalidMaxBytes
        case alreadyStarted
        case notStarted
        case failed
        case fileExists
        case io(errno: Int32)
        case audio(OSStatus)
        case exceedsLimit

        var errorDescription: String? {
            switch self {
            case .invalidMaxBytes: return "maxBytes must be positive"
            case .alreadyStarted: return "writer has already started"
            case .notStarted: return "writer has not started"
            case .failed: return "writer failed and cannot be reused"
            case .fileExists: return "destination already exists"
            case .io(let value): return String(cString: strerror(value))
            case .audio(let status): return "AudioToolbox error \(status)"
            case .exceedsLimit: return "CAF file exceeds maxBytes"
            }
        }
    }

    private let outputURL: URL
    private let sampleRate: Int
    private let bitRate: Int
    private let maxBytes: Int64
    private var fd: Int32 = -1
    private var audioFile: AudioFileID?
    private var extFile: ExtAudioFileRef?
    private var samplesWritten: Int64 = 0
    private var started = false
    private var finished = false
    private var stickyFailure = false

    init(outputURL: URL, sampleRate: Int = 16_000, bitRate: Int = 48_000, maxBytes: Int64) {
        self.outputURL = outputURL
        self.sampleRate = sampleRate
        self.bitRate = bitRate
        self.maxBytes = maxBytes
    }

    func start() throws {
        guard maxBytes > 0 else { throw Error.invalidMaxBytes }
        guard !started else { throw Error.alreadyStarted }
        let path = outputURL.path
        fd = path.withCString { open($0, O_RDWR | O_CREAT | O_EXCL, mode_t(0o600)) }
        guard fd >= 0 else {
            if errno == EEXIST { throw Error.fileExists }
            throw Error.io(errno: errno)
        }

        var format = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate), mFormatID: kAudioFormatOpus,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 320,
            mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        var af: AudioFileID?
        var status = AudioFileInitializeWithCallbacks(
            Unmanaged.passUnretained(self).toOpaque(), _boundedReadProc, _boundedWriteProc,
            _boundedGetSizeProc, _boundedSetSizeProc, kAudioFileCAFType, &format, [], &af)
        guard status == noErr, let af else { failAndClose(); throw Error.audio(status) }
        audioFile = af

        var ext: ExtAudioFileRef?
        status = ExtAudioFileWrapAudioFileID(af, true, &ext)
        guard status == noErr, let ext else { failAndCloseAudioFile(); throw Error.audio(status) }
        extFile = ext

        var client = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsFloat,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        status = ExtAudioFileSetProperty(ext, kExtAudioFileProperty_ClientDataFormat,
                                          UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        guard status == noErr else { failAndCloseAll(); throw Error.audio(status) }

        var converter: AudioConverterRef?
        var converterSize = UInt32(MemoryLayout<AudioConverterRef?>.size)
        status = ExtAudioFileGetProperty(ext, kExtAudioFileProperty_AudioConverter, &converterSize, &converter)
        guard status == noErr, let converter else { failAndCloseAll(); throw Error.audio(status) }
        var rate = UInt32(bitRate)
        status = AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate,
                                           UInt32(MemoryLayout<UInt32>.size), &rate)
        guard status == noErr else { failAndCloseAll(); throw Error.audio(status) }
        var config: CFPropertyList? = nil
        status = ExtAudioFileSetProperty(ext, kExtAudioFileProperty_ConverterConfig,
                                         UInt32(MemoryLayout<CFPropertyList?>.size), &config)
        guard status == noErr else { failAndCloseAll(); throw Error.audio(status) }
        started = true
    }

    func appendSamples(_ samples: [Float]) throws {
        guard started, !finished else { throw Error.notStarted }
        guard !stickyFailure else { throw Error.failed }
        guard !samples.isEmpty else { return }
        guard let ext = extFile else { throw Error.failed }
        try samples.withUnsafeBufferPointer { ptr in
            let buffer = AudioBuffer(mNumberChannels: 1,
                                     mDataByteSize: UInt32(samples.count * MemoryLayout<Float>.size),
                                     mData: UnsafeMutableRawPointer(mutating: ptr.baseAddress))
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: buffer)
            let status = ExtAudioFileWrite(ext, UInt32(samples.count), &list)
            guard status == noErr else { stickyFailure = true; throw Error.audio(status) }
        }
        samplesWritten += Int64(samples.count)
    }

    func finish() throws -> (duration: TimeInterval, fileSize: Int64) {
        guard started, !finished else { throw Error.notStarted }
        let hadStickyFailure = stickyFailure
        finished = true
        var failure: Swift.Error? = hadStickyFailure ? Error.failed : nil
        if let ext = extFile {
            let status = ExtAudioFileDispose(ext)
            extFile = nil
            if status != noErr { stickyFailure = true; failure = Error.audio(status) }
        }
        if let af = audioFile {
            let status = AudioFileClose(af)
            audioFile = nil
            if status != noErr, failure == nil { failure = Error.audio(status) }
        }
        if fd >= 0 {
            if fsync(fd) != 0, failure == nil { failure = Error.io(errno: errno) }
            if close(fd) != 0, failure == nil { failure = Error.io(errno: errno) }
            fd = -1
        }
        if stickyFailure, failure == nil { failure = Error.failed }
        if let failure { throw failure }
        var st = stat()
        let statResult = outputURL.path.withCString { stat($0, &st) }
        guard statResult == 0 else { throw Error.io(errno: errno) }
        guard st.st_size <= maxBytes else { throw Error.exceedsLimit }
        return (Double(samplesWritten) / Double(sampleRate), st.st_size)
    }

    deinit {
        if let ext = extFile { _ = ExtAudioFileDispose(ext) }
        if let af = audioFile { _ = AudioFileClose(af) }
        if fd >= 0 { _ = close(fd) }
    }

    private func failAndClose() { stickyFailure = true; if fd >= 0 { _ = close(fd); fd = -1 } }
    private func failAndCloseAudioFile() { if let af = audioFile { _ = AudioFileClose(af); audioFile = nil }; failAndClose() }
    private func failAndCloseAll() { if let ext = extFile { _ = ExtAudioFileDispose(ext); extFile = nil }; failAndCloseAudioFile() }

    private static func instance(_ data: UnsafeMutableRawPointer?) -> BoundedCAFWriter? {
        guard let data else { return nil }
        return Unmanaged<BoundedCAFWriter>.fromOpaque(data).takeUnretainedValue()
    }
    fileprivate static func readProc(_ data: UnsafeMutableRawPointer?, _ position: Int64, _ count: UInt32, _ buffer: UnsafeMutableRawPointer?, _ actual: UnsafeMutablePointer<UInt32>) -> OSStatus {
        guard let writer = instance(data), writer.fd >= 0, position >= 0, let buffer else { actual.pointee = 0; return kAudioFilePositionError }
        let result = pread(writer.fd, buffer, Int(count), off_t(position))
        if result < 0 { writer.stickyFailure = true; actual.pointee = 0; return -1 }
        actual.pointee = UInt32(result)
        return result == 0 && count > 0 ? kAudioFileEndOfFileError : noErr
    }
    fileprivate static func writeProc(_ data: UnsafeMutableRawPointer?, _ position: Int64, _ count: UInt32, _ buffer: UnsafeRawPointer?, _ actual: UnsafeMutablePointer<UInt32>) -> OSStatus {
        guard let writer = instance(data), let buffer, position >= 0 else { return kAudioFilePositionError }
        actual.pointee = 0
        guard !writer.stickyFailure, position <= writer.maxBytes, Int64(count) <= writer.maxBytes - position else { writer.stickyFailure = true; return kAudioFileOperationNotSupportedError }
        var written = 0
        while written < Int(count) {
            let result = pwrite(writer.fd, buffer.advanced(by: written), Int(count) - written, off_t(position) + off_t(written))
            if result <= 0 { writer.stickyFailure = true; return -1 }
            written += result
        }
        actual.pointee = count
        return noErr
    }
    fileprivate static func getSizeProc(_ data: UnsafeMutableRawPointer?) -> Int64 {
        guard let writer = instance(data), writer.fd >= 0 else { return 0 }
        var st = stat()
        guard fstat(writer.fd, &st) == 0 else { writer.stickyFailure = true; return 0 }
        return st.st_size
    }
    fileprivate static func setSizeProc(_ data: UnsafeMutableRawPointer?, _ size: Int64) -> OSStatus {
        guard let writer = instance(data), writer.fd >= 0, size >= 0, !writer.stickyFailure else { return kAudioFilePositionError }
        guard size <= writer.maxBytes else { writer.stickyFailure = true; return kAudioFileOperationNotSupportedError }
        guard ftruncate(writer.fd, off_t(size)) == 0 else { writer.stickyFailure = true; return -1 }
        return noErr
    }
}

private func _boundedReadProc(_ data: UnsafeMutableRawPointer, _ position: Int64, _ count: UInt32, _ buffer: UnsafeMutableRawPointer, _ actual: UnsafeMutablePointer<UInt32>) -> OSStatus {
    BoundedCAFWriter.readProc(data, position, count, buffer, actual)
}
private func _boundedWriteProc(_ data: UnsafeMutableRawPointer, _ position: Int64, _ count: UInt32, _ buffer: UnsafeRawPointer, _ actual: UnsafeMutablePointer<UInt32>) -> OSStatus {
    BoundedCAFWriter.writeProc(data, position, count, buffer, actual)
}
private func _boundedGetSizeProc(_ data: UnsafeMutableRawPointer) -> Int64 { BoundedCAFWriter.getSizeProc(data) }
private func _boundedSetSizeProc(_ data: UnsafeMutableRawPointer, _ size: Int64) -> OSStatus { BoundedCAFWriter.setSizeProc(data, size) }
