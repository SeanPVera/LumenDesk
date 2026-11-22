import AVFoundation
import Foundation

#if canImport(ShazamKit)
import ShazamKit

/// `TrackIdentifying` backed by ShazamKit. Streams captured buffers into an
/// `SHSession` and reports the matched media item's ISRC — the same audio
/// fingerprint path the iLightShow app itself uses to key its analysis.
///
/// ShazamKit identifies the *recording*, so a cover or live version resolves to
/// its own ISRC, which is exactly what the analysis API expects. One match is
/// reported per track; `reset()` builds a fresh session so the previous track's
/// accumulated signature cannot leak into the next identification.
final class ShazamTrackIdentifier: NSObject, TrackIdentifying, SHSessionDelegate {
    var onMatch: ((IdentifiedTrack) -> Void)?

    private let lock = NSLock()
    private var session: SHSession
    private var matched = false

    override init() {
        session = SHSession()
        super.init()
        session.delegate = self
    }

    func append(_ buffer: AVAudioPCMBuffer, at time: TimeInterval) {
        lock.lock()
        let active = !matched
        let session = self.session
        lock.unlock()
        guard active else { return }
        session.matchStreamingBuffer(buffer, at: nil)
    }

    func reset() {
        let fresh = SHSession()
        fresh.delegate = self
        lock.lock()
        session = fresh
        matched = false
        lock.unlock()
    }

    func session(_ session: SHSession, didFind match: SHMatch) {
        guard let item = match.mediaItems.first, let isrc = item.isrc, !isrc.isEmpty else { return }
        lock.lock()
        let already = matched
        matched = true
        lock.unlock()
        guard !already else { return }
        onMatch?(IdentifiedTrack(isrc: isrc, title: item.title, artist: item.artist))
    }
}
#endif
