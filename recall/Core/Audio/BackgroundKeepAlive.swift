import AVFoundation
import MediaPlayer
import OSLog
import UIKit

/// Plays inaudible silent audio + sets NowPlaying info to convince iOS
/// that recall is a "media playback app", raising audio session priority
/// and preventing background termination.
@MainActor
final class BackgroundKeepAlive {

    static let shared = BackgroundKeepAlive()

    private var player: AVAudioPlayer?
    private let logger = Logger(subsystem: "com.example.recall", category: "KeepAlive")
    private let activity = ActivityLogger.shared

    private init() {}

    // MARK: - Public API

    func start() {
        guard player == nil || player?.isPlaying != true else {
            logger.info("Keep-alive already running")
            return
        }

        do {
            let data = generateSilentWAV()
            let p = try AVAudioPlayer(data: data)
            p.numberOfLoops = -1   // infinite loop
            p.volume = 0.01        // near-silent
            p.play()
            player = p
            logger.info("Keep-alive started (silent playback)")
            activity.log(.state, "Keep-alive started")
        } catch {
            logger.error("Failed to start keep-alive player: \(error.localizedDescription)")
            activity.log(.error, "Keep-alive start failed: \(error.localizedDescription)")
            return
        }

        setupNowPlaying()
        setupRemoteCommands()
        UIApplication.shared.beginReceivingRemoteControlEvents()
    }

    func stop() {
        player?.stop()
        player = nil

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)

        logger.info("Keep-alive stopped")
        activity.log(.state, "Keep-alive stopped")
    }

    func resumePlayback() {
        guard let player else {
            // Player was never created or was stopped — full restart
            start()
            return
        }
        guard !player.isPlaying else { return }

        player.play()
        logger.info("Keep-alive resumed")
        activity.log(.state, "Keep-alive resumed")
    }

    // MARK: - Silent WAV Generation

    /// Generates a 1-second 16kHz mono 16-bit PCM WAV with all-zero samples.
    private func generateSilentWAV() -> Data {
        let sampleRate: UInt32 = 16_000
        let bitsPerSample: UInt16 = 16
        let channels: UInt16 = 1
        let durationSeconds: UInt32 = 1

        let dataSize = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8) * durationSeconds
        let fileSize = 36 + dataSize  // total - 8 bytes for RIFF header

        var wav = Data(capacity: Int(44 + dataSize))

        // RIFF header
        wav.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        wav.appendLittleEndian(fileSize)
        wav.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"

        // fmt subchunk
        wav.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        wav.appendLittleEndian(UInt32(16))                 // subchunk size
        wav.appendLittleEndian(UInt16(1))                  // PCM format
        wav.appendLittleEndian(channels)
        wav.appendLittleEndian(sampleRate)
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        wav.appendLittleEndian(byteRate)
        let blockAlign = channels * (bitsPerSample / 8)
        wav.appendLittleEndian(blockAlign)
        wav.appendLittleEndian(bitsPerSample)

        // data subchunk
        wav.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        wav.appendLittleEndian(dataSize)
        wav.append(Data(count: Int(dataSize)))             // zero-filled PCM

        return wav
    }

    // MARK: - NowPlaying

    private func setupNowPlaying() {
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = "recall Recording"
        info[MPMediaItemPropertyArtist] = "recall"
        info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Remote Commands

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        // Minimal handlers — iOS requires these to show NowPlaying controls
        center.playCommand.addTarget { [weak self] _ in
            self?.player?.play()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            // Don't actually pause — we want to keep playing
            self?.player?.play()
            return .success
        }
    }
}

// MARK: - Data Helpers

private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
