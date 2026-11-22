import AVFoundation
import Foundation

/// A track identified from the audio Music Mode is already capturing, carrying
/// the ISRC the iLightShow analysis API is keyed by.
struct IdentifiedTrack: Equatable {
    let isrc: String
    let title: String?
    let artist: String?
}

/// Identifies the playing track from streamed PCM so Music Mode can fetch a
/// precomputed beat map for it. Fed the same buffers the analyzer sees; reports
/// at most one match per track until `reset()` starts a new identification.
///
/// `append` is called from the audio-analysis queue, `reset` and `onMatch` are
/// used on the main actor — implementations keep their own state consistent.
protocol TrackIdentifying: AnyObject {
    /// Called once when the current track is identified.
    var onMatch: ((IdentifiedTrack) -> Void)? { get set }
    /// Feed one buffer of captured audio toward the current identification.
    func append(_ buffer: AVAudioPCMBuffer, at time: TimeInterval)
    /// Forget the current match and start identifying afresh (new track).
    func reset()
}
