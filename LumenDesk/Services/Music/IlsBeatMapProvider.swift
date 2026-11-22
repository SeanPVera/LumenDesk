import Foundation

/// Fetches a decoded iLightShow analysis for an ISRC. `IlsClient` conforms;
/// tests inject a stub.
protocol IlsAnalysisFetching: Sendable {
    func analysis(for isrc: String) async throws -> IlsAnalysis
}

extension IlsClient: IlsAnalysisFetching {}

/// Supplies a precomputed `BeatMap` for a track's ISRC. The coordinator asks
/// for one when a track is identified; a nil result means "fall back to live
/// analysis", so every failure path returns nil rather than throwing.
protocol IlsBeatMapProviding: Sendable {
    func beatMap(forISRC isrc: String) async -> BeatMap?
}

/// Turns an ISRC into a `BeatMap` via the iLightShow API: enrol once, fetch,
/// decode, map, cache.
///
/// Designed to degrade silently. A per-ISRC miss set means a track with no
/// server analysis is asked for only once per session; a tripped enrolment
/// breaker means an unreachable or not-yet-provisioned backend stops being
/// hammered after the first failure, so Music Mode just keeps using its live
/// map. The backend Option A patch (DPoP-only macOS enrol) must be live for
/// this to return maps; until then it fails closed on the first attempt.
actor IlsBeatMapProvider: IlsBeatMapProviding {
    private let fetcher: IlsAnalysisFetching
    private let prepare: @Sendable () async throws -> Void

    private var cache: [String: BeatMap] = [:]
    private var misses: Set<String> = []
    private var prepared = false
    private var preparationFailed = false

    /// - Parameters:
    ///   - fetcher: fetches the raw analysis (production: an `IlsClient`).
    ///   - prepare: one-time setup before the first fetch (production: enrol).
    init(fetcher: IlsAnalysisFetching, prepare: @escaping @Sendable () async throws -> Void) {
        self.fetcher = fetcher
        self.prepare = prepare
    }

    /// Convenience production provider backed by a fresh `IlsClient`.
    static func live() -> IlsBeatMapProvider? {
        guard let client = try? IlsClient() else { return nil }
        return IlsBeatMapProvider(fetcher: client, prepare: { try await client.ensureEnrolled() })
    }

    func beatMap(forISRC isrc: String) async -> BeatMap? {
        if let cached = cache[isrc] { return cached }
        guard !misses.contains(isrc), !preparationFailed else { return nil }

        if !prepared {
            do {
                try await prepare()
                prepared = true
            } catch {
                // Enrolment failed (backend not provisioned, offline, …) —
                // stop trying for the rest of the session.
                preparationFailed = true
                return nil
            }
        }

        do {
            let analysis = try await fetcher.analysis(for: isrc)
            guard let map = analysis.beatMap, map.isPlayable else {
                misses.insert(isrc)
                return nil
            }
            cache[isrc] = map
            return map
        } catch {
            // No analysis for this track (or a transient fetch error): don't
            // ask again this session, but keep the provider available for
            // other tracks.
            misses.insert(isrc)
            return nil
        }
    }
}
