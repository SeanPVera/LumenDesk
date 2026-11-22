import CryptoKit
import XCTest
@testable import LumenDesk

/// End-to-end tests for the iLightShow bundle pipeline:
/// protobuf → Brotli → AES-256-GCM, plus the BeatMap mapping.
///
/// The fixtures are hand-encoded protobuf vectors using the exact field
/// numbers from the 4.0.0-beta generated classes (`defpackage/b.java`,
/// `defpackage/c.java`), compressed with the same vendored Brotli the
/// server uses.
final class IlsBundleTests: XCTestCase {
    // MARK: - Brotli

    func testBrotliRoundTrip() throws {
        let payload = Self.samplePayload()
        let compressed = try XCTUnwrap(IlsBrotli.compress(payload))
        XCTAssertTrue(compressed.count < payload.count)
        XCTAssertEqual(IlsBrotli.decompress(compressed), payload)
    }

    func testBrotliRejectsGarbage() {
        XCTAssertNil(IlsBrotli.decompress([0xFF, 0xFF, 0xFF, 0xFF, 0xFF]))
        XCTAssertNil(IlsBrotli.decompress([]))
    }

    // MARK: - Protobuf decoding

    func testProtobufItemDecode() throws {
        let item = try IlsProtobuf.decodeItem(Self.sampleItemBytes())
        XCTAssertEqual(item.frameInTrack, 500)
        XCTAssertEqual(item.frameInPortion, 7)
        XCTAssertTrue(item.beat)
        XCTAssertTrue(item.drum)
        XCTAssertFalse(item.downbeat)
        XCTAssertFalse(item.strobe)
        XCTAssertEqual(item.timeBeforeNextBeat, 0.5)
        XCTAssertEqual(item.timeBeforeNextDrum, 0.25)
        XCTAssertEqual(item.drumAct, 200)
        XCTAssertEqual(item.time, 5.0, accuracy: 0.0001)
    }

    func testProtobufAnalysisDecode() throws {
        let analysis = try IlsProtobuf.decodeAnalysis(Self.sampleAnalysisBytes())
        XCTAssertEqual(analysis.duration, 120, accuracy: 0.0001)
        XCTAssertEqual(analysis.title, "Test Title")
        XCTAssertEqual(analysis.artist, "Test Artist")
        XCTAssertEqual(analysis.isrc, "USUMG7100123")
        XCTAssertEqual(analysis.chromaprint, "AQAL")
        XCTAssertEqual(analysis.tempo, 120, accuracy: 0.0001)
        XCTAssertEqual(analysis.items.count, 2)
        XCTAssertEqual(analysis.items[0].frameInTrack, 500)
    }

    func testProtobufSkipsUnknownFields() throws {
        var bytes = Self.sampleItemBytes()
        // Unknown varint field 42 (tag 0xD0 0x02), then a known one (field 9, beat).
        bytes.append(contentsOf: [0xD0, 0x02, 0x05])
        bytes.append(contentsOf: [0x48, 0x01])
        let item = try IlsProtobuf.decodeItem(bytes)
        XCTAssertTrue(item.beat)
        XCTAssertEqual(item.frameInTrack, 500)
    }

    // MARK: - GCM + full pipeline

    func testSealOpenRoundTrip() throws {
        let nonce = [UInt8](1...12)
        let plain = Self.samplePayload()
        let sealed = try IlsCrypto.seal(plain: plain, nonce: nonce)
        XCTAssertEqual(Array(sealed.prefix(12)), nonce)
        let opened = try IlsCrypto.openBundle(sealed)
        XCTAssertEqual(opened, plain)
    }

    func testSealOpenRejectsTamper() {
        let nonce = [UInt8](repeating: 9, count: 12)
        let plain = Self.samplePayload()
        var sealed = try! IlsCrypto.seal(plain: plain, nonce: nonce)
        sealed[sealed.count - 1] ^= 0xFF
        XCTAssertThrowsError(try IlsCrypto.openBundle(sealed)) { error in
            guard case IlsCrypto.BundleError.authenticationFailed = error else {
                return XCTFail("expected authenticationFailed, got \(error)")
            }
        }
    }

    func testFullPipelineDecode() throws {
        // Exactly the server's order: protobuf → Brotli → GCM (`seal`
        // does the Brotli step itself).
        let sealed = try IlsCrypto.seal(plain: Self.sampleAnalysisBytes(), nonce: [UInt8](1...12))

        let decoded = try IlsCrypto.decodeBundle(sealed)
        XCTAssertEqual(decoded.duration, 120, accuracy: 0.0001)
        XCTAssertEqual(decoded.title, "Test Title")
        XCTAssertEqual(decoded.items.count, 2)
    }

    // MARK: - BeatMap mapping

    func testAnalysisToBeatMap() throws {
        let analysis = Self.syntheticAnalysis()
        guard let result = analysis.beatMap else {
            return XCTFail("expected a playable map for a synthetic 120 BPM timeline")
        }
        XCTAssertTrue(result.isPlayable)
        XCTAssertEqual(result.tempo, 120, accuracy: 0.01)
        XCTAssertEqual(result.beats.count, 41)
        XCTAssertEqual(try XCTUnwrap(result.beats.first), 0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.beats.last), 20, accuracy: 0.0001)
        XCTAssertEqual(result.downbeatOffset, 0)
        XCTAssertEqual(result.envelope.count, 2001)
        XCTAssertEqual(result.envelope[50], 1.0, accuracy: 0.0001)
        XCTAssertEqual(result.envelope[75], 0.7, accuracy: 0.0001)
        XCTAssertFalse(result.barEnergy.isEmpty)
    }

    func testAnalysisToBeatMapDownbeatOffset() {
        // Downbeats land on beat indices 2 and 6 → phase 2.
        let analysis = Self.syntheticAnalysis(downbeatsAt: [100, 300])
        guard let map = analysis.beatMap else {
            return XCTFail("expected a map")
        }
        XCTAssertEqual(map.downbeatOffset, 2)
    }

    // MARK: - DPoP

    func testDPoPProofIsES256WithRawSignature() throws {
        let key = IlsDPoPKey(privateKey: P256.Signing.PrivateKey())
        let proof = try IlsDPoP.proof(
            key: key,
            method: "GET",
            url: "https://example.invalid/ils/v3/isrc/TEST",
            nonce: "n-1",
            accessToken: "token"
        )
        let parts = proof.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)

        // ES256 (RFC 7518 §3.4) is raw r || s, 64 bytes — never DER.
        let signature = try XCTUnwrap(Self.base64URLDecode(parts[2]))
        XCTAssertEqual(signature.count, 64)
        let ecdsa = try P256.Signing.ECDSASignature(rawRepresentation: signature)
        XCTAssertTrue(key.publicKey.isValidSignature(ecdsa, for: Data((parts[0] + "." + parts[1]).utf8)))

        let header = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(Self.base64URLDecode(parts[0]))) as? [String: Any]
        )
        XCTAssertEqual(header["alg"] as? String, "ES256")
        XCTAssertEqual(header["typ"] as? String, "dpop+jwt")
        let jwk = try XCTUnwrap(header["jwk"] as? [String: String])
        XCTAssertEqual(jwk, key.jwkDictionary)
        let point = key.publicKey.rawRepresentation
        XCTAssertEqual(Self.base64URLDecode(try XCTUnwrap(jwk["x"])), Data(point.prefix(32)))
        XCTAssertEqual(Self.base64URLDecode(try XCTUnwrap(jwk["y"])), Data(point.suffix(32)))
    }

    private static func base64URLDecode(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    // MARK: - Fixtures

    /// ~4 KB of text resembling a real analysis payload.
    private static func samplePayload() -> [UInt8] {
        var text = ""
        for i in 0..<400 {
            text += "{\"frame\":\(i),\"beat\":\(i % 8 == 0),\"energy\":\(Double(i) / 400.0),\"label\":\"sample-payload-#{i}\"}\n"
        }
        return Array(text.utf8)
    }

    /// A hand-encoded item message:
    /// field 1 (varint 500), field 2 (varint 7), field 3 (bool true),
    /// field 4 (varint 200), field 9 (bool true), field 17 (double 0.25),
    /// field 18 (double 0.5).
    private static func sampleItemBytes() -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.append(contentsOf: [0x08, 0xF4, 0x03])        // 1: 500
        bytes.append(contentsOf: [0x10, 0x07])              // 2: 7
        bytes.append(contentsOf: [0x18, 0x01])              // 3: drum = true
        bytes.append(contentsOf: [0x20, 0xC8, 0x01])        // 4: drumAct = 200
        bytes.append(contentsOf: [0x48, 0x01])              // 9: beat = true
        bytes.append(contentsOf: [0x89, 0x01])              // 17: tag
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xD0, 0x3F])  // 0.25 LE
        bytes.append(contentsOf: [0x91, 0x01])              // 18: tag
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xE0, 0x3F])  // 0.5 LE
        return bytes
    }

    /// A hand-encoded root analysis message with two items.
    private static func sampleAnalysisBytes() -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.append(0x09)  // 1: duration (double)
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x5E, 0x40])  // 120.0 LE
        bytes.append(contentsOf: [0x12, 10])  // 2: title (len 10)
        bytes.append(contentsOf: Array("Test Title".utf8))
        bytes.append(contentsOf: [0x1A, 11])  // 3: artist (len 11)
        bytes.append(contentsOf: Array("Test Artist".utf8))
        bytes.append(contentsOf: [0x22, 12])  // 4: isrc (len 12)
        bytes.append(contentsOf: Array("USUMG7100123".utf8))
        bytes.append(contentsOf: [0x2A, 4])   // 5: shazam (bytes, len 4)
        bytes.append(contentsOf: [0xAA, 0xBB, 0xCC, 0xDD])
        bytes.append(contentsOf: [0x3A, 4])   // 7: chromaprint (len 4)
        bytes.append(contentsOf: Array("AQAL".utf8))
        let item = sampleItemBytes()
        bytes.append(contentsOf: [0x42, UInt8(item.count)])  // 8: item
        bytes.append(contentsOf: item)
        bytes.append(contentsOf: [0x42, UInt8(item.count)])  // 8: item
        bytes.append(contentsOf: item)
        bytes.append(0x49)  // 9: tempo (double)
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x5E, 0x40])  // 120.0 LE
        return bytes
    }

    /// A synthetic 120 BPM analysis: beats every 0.5 s, drums on every
    /// beat and on every off-beat (drum-only items), downbeats on the
    /// given frames (default: bar starts).
    private static func syntheticAnalysis(downbeatsAt frames: [Int] = [0, 200, 400, 600, 800, 1000, 1200, 1400, 1600, 1800, 2000]) -> IlsAnalysis {
        var analysis = IlsAnalysis()
        analysis.duration = 20
        analysis.tempo = 120
        analysis.title = "Synthetic"
        analysis.artist = "LumenDesk"
        analysis.isrc = "TEST-2026-0001"
        let downbeats = Set(frames)
        for frame in stride(from: 0, through: 2000, by: 50) {
            var item = IlsAnalysis.IlsItem()
            item.frameInTrack = frame
            item.beat = true
            item.drum = true
            item.downbeat = downbeats.contains(frame)
            analysis.items.append(item)
            if frame < 2000 {
                var offBeat = IlsAnalysis.IlsItem()
                offBeat.frameInTrack = frame + 25
                offBeat.drum = true
                analysis.items.append(offBeat)
            }
        }
        return analysis
    }
}
