import Foundation

/// Swift bindings for the vendored Brotli C library (RFC 7932).
///
/// The sources live under `Vendor/brotli` (MIT; see `Vendor/brotli/LICENSE`).
/// Only the one-shot API is exposed — the streaming variants are unused by
/// LumenDesk.
enum IlsBrotli {
    /// Hard ceiling on decompressed output. Analysis timelines are a few
    /// hundred KB; this caps the damage a decompression-bomb (or a buggy
    /// server) can do on the music path.
    static let maxOutputBytes = 16 * 1024 * 1024

    /// Decodes a Brotli stream. The one-shot decoder reports a too-small
    /// output buffer as `ERROR` (not `NEEDS_MORE_OUTPUT`), so a failure that
    /// filled the whole buffer is retried with double the capacity, up to
    /// `maxOutputBytes`. Returns nil when `input` is empty, not a valid
    /// stream, or expands past the cap.
    static func decompress(_ input: [UInt8]) -> [UInt8]? {
        guard !input.isEmpty else { return nil }
        var capacity = min(max(input.count * 4, 64 * 1024), maxOutputBytes)
        let maxCapacity = maxOutputBytes
        while true {
            var output = [UInt8](repeating: 0, count: capacity)
            // In/out: the buffer's capacity going in, bytes written coming out.
            var decodedSize = capacity
            let result = output.withUnsafeMutableBufferPointer { outPtr in
                input.withUnsafeBufferPointer { inPtr in
                    BrotliDecoderDecompress(input.count, inPtr.baseAddress, &decodedSize, outPtr.baseAddress)
                }
            }
            if result == BROTLI_DECODER_RESULT_SUCCESS {
                return Array(output.prefix(decodedSize))
            }
            guard decodedSize >= capacity, capacity < maxCapacity else { return nil }
            capacity = min(capacity * 2, maxCapacity)
        }
    }

    #if DEBUG
    /// Encodes with quality 5, window 22, generic mode. Used only by tests to
    /// build realistic fixtures; production encoding happens server-side, so
    /// this (and the linked Brotli encoder) is excluded from Release builds.
    static func compress(_ input: [UInt8]) -> [UInt8]? {
        // Large enough for any input, so a single call always fits.
        let capacity = BrotliEncoderMaxCompressedSize(input.count)
        guard capacity > 0 else { return nil }
        var output = [UInt8](repeating: 0, count: capacity)
        var encodedSize = capacity
        let ok = output.withUnsafeMutableBufferPointer { outPtr in
            input.withUnsafeBufferPointer { inPtr in
                BrotliEncoderCompress(
                    5,
                    22,
                    BrotliEncoderMode(rawValue: 0), // BROTLI_MODE_GENERIC
                    input.count,
                    inPtr.baseAddress,
                    &encodedSize,
                    outPtr.baseAddress
                )
            }
        }
        guard ok != 0 else { return nil }
        return Array(output.prefix(encodedSize))
    }
    #endif
}
