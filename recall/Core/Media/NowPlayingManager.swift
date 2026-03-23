import Foundation
import Observation

/// Passively observes system now-playing info via MediaRemote.framework (private API).
/// Read-only — never writes to NowPlayingInfoCenter or registers remote commands,
/// so it does NOT interfere with companion apps' Live Activity on the lock screen.
@Observable
@MainActor
final class NowPlayingManager {

    private(set) var isEnabled = false
    private(set) var title: String?
    private(set) var artist: String?
    private(set) var album: String?
    private(set) var isPlaying = false
    private(set) var lastChange: Date?

    private var mediaRemote: MediaRemoteBridge?

    func restoreSettings() {
        if AppSettings.shared.nowPlayingEnabled {
            isEnabled = true
            start()
        }
    }

    func start() {
        guard mediaRemote == nil else { return }
        guard let bridge = MediaRemoteBridge() else {
            ActivityLogger.shared.log(.telemetry, "NowPlaying: MediaRemote.framework not available")
            isEnabled = true
            return
        }
        mediaRemote = bridge
        bridge.start { [weak self] info in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let changed = self.title != info.title || self.artist != info.artist
                self.title = info.title
                self.artist = info.artist
                self.album = info.album
                self.isPlaying = info.isPlaying
                self.lastChange = Date()
                if changed, let t = info.title {
                    ActivityLogger.shared.log(.telemetry, "NowPlaying: \(t) — \(info.artist ?? "?")")
                }
            }
        }
        isEnabled = true
        ActivityLogger.shared.log(.telemetry, "NowPlaying: started (MediaRemote read-only)")
    }

    func stop() {
        mediaRemote?.stop()
        mediaRemote = nil
        isEnabled = false
        title = nil
        artist = nil
        album = nil
        isPlaying = false
        ActivityLogger.shared.log(.telemetry, "NowPlaying: stopped")
    }

    var snapshot: NowPlayingSnapshot? {
        guard isEnabled, isPlaying, title != nil else { return nil }
        return NowPlayingSnapshot(
            title: title,
            artist: artist,
            album: album,
            timestamp: lastChange ?? Date()
        )
    }
}

struct NowPlayingSnapshot: Encodable {
    let title: String?
    let artist: String?
    let album: String?
    let timestamp: Date
}

// MARK: - MediaRemote.framework Bridge (Private API, read-only)

/// Dynamically loads MediaRemote.framework and exposes read-only now-playing queries.
/// Never calls write/set/command APIs — safe for coexistence with other apps' Live Activities.
private final class MediaRemoteBridge {

    struct TrackInfo {
        var title: String?
        var artist: String?
        var album: String?
        var isPlaying: Bool = false
    }

    // Function pointer types matching MediaRemote C API
    private typealias RegisterFn = @convention(c) (DispatchQueue) -> Void
    private typealias UnregisterFn = @convention(c) () -> Void
    private typealias GetInfoCompletion = @convention(block) (CFDictionary?) -> Void
    private typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping GetInfoCompletion) -> Void
    private typealias GetIsPlayingCompletion = @convention(block) (Bool) -> Void
    private typealias GetIsPlayingFn = @convention(c) (DispatchQueue, @escaping GetIsPlayingCompletion) -> Void

    private let bundle: CFBundle
    private let registerFn: RegisterFn
    private let unregisterFn: UnregisterFn
    private let getInfoFn: GetInfoFn
    private let getIsPlayingFn: GetIsPlayingFn
    private var observers: [NSObjectProtocol] = []

    init?() {
        let url = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
        guard let bundle = CFBundleCreate(kCFAllocatorDefault, url as CFURL) else { return nil }
        self.bundle = bundle

        func load<T>(_ name: String, as type: T.Type) -> T? {
            guard let ptr = CFBundleGetFunctionPointerForName(bundle, name as CFString) else { return nil }
            return unsafeBitCast(ptr, to: type)
        }

        guard
            let registerFn = load("MRMediaRemoteRegisterForNowPlayingNotifications", as: RegisterFn.self),
            let unregisterFn = load("MRMediaRemoteUnregisterForNowPlayingNotifications", as: UnregisterFn.self),
            let getInfoFn = load("MRMediaRemoteGetNowPlayingInfo", as: GetInfoFn.self),
            let getIsPlayingFn = load("MRMediaRemoteGetNowPlayingApplicationIsPlaying", as: GetIsPlayingFn.self)
        else { return nil }

        self.registerFn = registerFn
        self.unregisterFn = unregisterFn
        self.getInfoFn = getInfoFn
        self.getIsPlayingFn = getIsPlayingFn
    }

    func start(onUpdate: @escaping (TrackInfo) -> Void) {
        registerFn(.main)

        let names: [Notification.Name] = [
            .init("kMRMediaRemoteNowPlayingInfoDidChangeNotification"),
            .init("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"),
            .init("kMRMediaRemoteNowPlayingApplicationDidChangeNotification"),
        ]

        for name in names {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.fetch(onUpdate: onUpdate)
            }
            observers.append(token)
        }

        // Initial fetch
        fetch(onUpdate: onUpdate)
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        unregisterFn()
    }

    private func fetch(onUpdate: @escaping (TrackInfo) -> Void) {
        getInfoFn(.main) { [weak self] cfDict in
            var info = TrackInfo()

            if let dict = cfDict as? [String: Any] {
                info.title = dict["kMRMediaRemoteNowPlayingInfoTitle"] as? String
                info.artist = dict["kMRMediaRemoteNowPlayingInfoArtist"] as? String
                info.album = dict["kMRMediaRemoteNowPlayingInfoAlbum"] as? String
            }

            self?.getIsPlayingFn(.main) { isPlaying in
                info.isPlaying = isPlaying
                onUpdate(info)
            }
        }
    }
}
