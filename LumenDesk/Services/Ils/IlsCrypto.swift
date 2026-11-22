import CryptoKit
import Foundation

/// The bundle crypto used by the iLightShow API.
///
/// Wire format (verified against the 4.0.0-beta APK, `Services/Z.java`):
/// `12-byte nonce || AES-256-GCM ciphertext || 16-byte auth tag`, whose
/// plaintext is a Brotli stream of a protobuf payload.
///
/// The key is not sent over the wire — the app derives it at runtime by
/// XORing the two 32-byte halves of a 64-byte literal embedded in the
/// binary (`Z.e` feeds `Z.h`). We mirror that derivation.
enum IlsCrypto {
    /// Errors from the decrypt pipeline.
    enum BundleError: Error, Equatable {
        case tooShort
        case authenticationFailed
        case brotliFailed
        case protobuf(IlsDecodeError)
    }

    /// The 64-byte literal from the APK source (`Z.java:44`).
    private static let keyMaterial: [UInt8] = [
        0x13, 0xD8, 0x9C, 0xD3, 0x0A, 0x55, 0x45, 0x16,
        0x30, 0x5E, 0x8A, 0x47, 0x24, 0xF2, 0xB5, 0x23,
        0xD6, 0xC9, 0x6B, 0x60, 0xD8, 0x1C, 0x3C, 0xE8,
        0x94, 0x3D, 0x49, 0x7B, 0x47, 0x38, 0x8B, 0xD8,
        0xA2, 0x0B, 0x9A, 0xDD, 0x67, 0x62, 0x81, 0x0A,
        0x89, 0x71, 0x47, 0x84, 0xDB, 0x03, 0xAF, 0x6A,
        0xD2, 0xB8, 0x4F, 0x24, 0x1F, 0x59, 0x34, 0x2D,
        0x4E, 0x23, 0xFC, 0xA6, 0x8E, 0xBD, 0x87, 0x6E,
    ]

    /// The effective AES-256 key: first half XOR second half, mirroring
    /// `Z.h()` in the APK.
    static var effectiveKey: SymmetricKey {
        var key = [UInt8](repeating: 0, count: 32)
        for index in 0..<32 {
            key[index] = keyMaterial[index] ^ keyMaterial[index + 32]
        }
        return SymmetricKey(data: Data(key))
    }

    /// Decrypts and decompresses a bundle (`nonce || ciphertext || tag`).
    static func openBundle(_ data: [UInt8]) throws -> [UInt8] {
        guard data.count >= 12 + 16 else { throw BundleError.tooShort }
        let nonce = try AES.GCM.Nonce(data: Data(data.prefix(12)))
        let ciphertext = Data(data[12..<(data.count - 16)])
        let tag = Data(data.suffix(16))
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(
                AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag),
                using: effectiveKey
            )
        } catch {
            throw BundleError.authenticationFailed
        }
        guard let decoded = IlsBrotli.decompress([UInt8](plaintext)) else {
            throw BundleError.brotliFailed
        }
        return decoded
    }

    /// The full server → model pipeline: GCM → Brotli → protobuf.
    static func decodeBundle(_ data: [UInt8]) throws -> IlsAnalysis {
        do {
            let plain = try openBundle(data)
            return try IlsProtobuf.decodeAnalysis(plain)
        } catch let error as IlsDecodeError {
            throw BundleError.protobuf(error)
        }
    }

    #if DEBUG
    /// Encrypts and compresses — used only by tests to build synthetic
    /// bundles in the exact server format. Excluded from Release (production
    /// only ever decrypts), which keeps the Brotli encoder out of the
    /// shipping binary.
    static func seal(plain: [UInt8], nonce: [UInt8]) throws -> [UInt8] {
        guard nonce.count == 12 else { throw BundleError.tooShort }
        guard let compressed = IlsBrotli.compress(plain) else { throw BundleError.brotliFailed }
        let nonceData = Data(nonce)
        let sealed = try AES.GCM.seal(
            Data(compressed),
            using: effectiveKey,
            nonce: AES.GCM.Nonce(data: nonceData)
        )
        return nonce + [UInt8](sealed.ciphertext) + [UInt8](sealed.tag)
    }
    #endif
}
