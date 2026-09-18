import AVFoundation
import Foundation

/// The part of an audio error that a log line usually drops.
///
/// iOS reports audio session refusals with a localized sentence ("Session activation
/// failed") that says nothing about *why*. The reason lives in the code: `!pri` means
/// another session has higher priority (a call), `!int` means a background app may not
/// interrupt the one in front, `what` is the media server not answering. On 2026-09-18 the
/// recording stayed stopped for ten and a half hours and the log could not say which of
/// these it was, so every failure now carries its domain and code.
extension Error {
    var audioDiagnostic: String {
        let error = self as NSError
        return "\(error.localizedDescription) [\(error.domain) \(error.code)\(Self.fourCharacterCode(error.code))]"
    }

    /// Core Audio codes are four ASCII characters packed into an integer.
    private static func fourCharacterCode(_ code: Int) -> String {
        let value = UInt32(truncatingIfNeeded: code)
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }),
              let text = String(bytes: bytes, encoding: .ascii) else { return "" }
        return " '\(text)'"
    }
}

/// The state of the audio session at the moment something happened to it, for the log.
enum AudioSessionSnapshot {
    static func describe() -> String {
        let session = AVAudioSession.sharedInstance()
        let input = session.currentRoute.inputs.first?.portType.rawValue ?? "none"
        let output = session.currentRoute.outputs.first?.portType.rawValue ?? "none"
        let app = ConnectivityMonitor.shared.isAppActive ? "fg" : "bg"
        return "app=\(app) in=\(input) out=\(output) other=\(session.isOtherAudioPlaying) silenceHint=\(session.secondaryAudioShouldBeSilencedHint)"
    }
}
