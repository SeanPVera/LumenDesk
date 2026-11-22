import CryptoKit
import Foundation
import Security

/// Errors from the DPoP key and proof machinery.
enum DPoPError: Error, Equatable {
    case keyCreationFailed
    case keyImportFailed
    case signatureFailed
}

/// A P-256 keypair for DPoP proofs (RFC 9449), persisted in the Keychain.
///
/// Matches the iLightShow auth model: a long-lived P-256 key (the app uses
/// a Keystore key with alias `ilightshow-app-dpop-v1`) whose JWK is
/// presented at challenge time, with every request carrying a JWT proof
/// signed by that key (`C0679t` in the 4.0.0-beta APK).
final class IlsDPoPKey: @unchecked Sendable {
    private static let keyAccount = "com.lumendesk.ilightshow.dpop.v1"
    private static let service = "com.lumendesk.LumenDesk"

    private let privateKey: P256.Signing.PrivateKey
    private let jwkX: Data
    private let jwkY: Data

    /// Loads the persisted key when one exists, otherwise generates and
    /// stores a fresh one.
    convenience init() throws {
        if let stored = IlsKeychain.load(account: Self.keyAccount, service: Self.service),
           let key = Self.importPrivateKey(stored) {
            self.init(privateKey: key)
            return
        }
        let key = P256.Signing.PrivateKey()
        // A failed save only costs a re-enrollment next launch; keep going.
        IlsKeychain.save(key.rawRepresentation, account: Self.keyAccount, service: Self.service)
        self.init(privateKey: key)
    }

    /// Wraps an existing key without touching the Keychain (tests).
    init(privateKey: P256.Signing.PrivateKey) {
        self.privateKey = privateKey
        // Raw public key is x || y, 32 bytes each — the two JWK coordinates.
        let point = privateKey.publicKey.rawRepresentation
        jwkX = Data(point.prefix(32))
        jwkY = Data(point.suffix(32))
    }

    /// Imports the stored scalar (32 bytes), or an X9.63 `04||x||y||d` blob.
    private static func importPrivateKey(_ data: Data) -> P256.Signing.PrivateKey? {
        if let key = try? P256.Signing.PrivateKey(rawRepresentation: data) { return key }
        return try? P256.Signing.PrivateKey(x963Representation: data)
    }

    var publicKey: P256.Signing.PublicKey { privateKey.publicKey }

    /// The JWK fragment for DPoP proof headers —
    /// `"jwk":{"kty":"EC","crv":"P-256","x":"…","y":"…"}`.
    var jwkFragment: String {
        "\"jwk\":{\"kty\":\"EC\",\"crv\":\"P-256\",\"x\":\"\(IlsDPoP.base64URL(jwkX))\",\"y\":\"\(IlsDPoP.base64URL(jwkY))\"}"
    }

    /// The JWK as a dictionary, for the challenge body's `public_key`.
    var jwkDictionary: [String: String] {
        ["kty": "EC", "crv": "P-256", "x": IlsDPoP.base64URL(jwkX), "y": IlsDPoP.base64URL(jwkY)]
    }

    /// Signs with ECDSA P-256/SHA-256, returning the raw 64-byte `r || s`
    /// that ES256 requires (RFC 7518 §3.4) — not DER.
    func sign(_ message: Data) throws -> Data {
        do {
            return try privateKey.signature(for: message).rawRepresentation
        } catch {
            throw DPoPError.signatureFailed
        }
    }
}

/// A minimal Keychain store for the DPoP key.
enum IlsKeychain {
    @discardableResult
    static func save(_ data: Data, account: String, service: String) -> Bool {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: account,
            kSecAttrService: service,
        ] as CFDictionary)
        return SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: account,
            kSecAttrService: service,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ] as CFDictionary, nil) == errSecSuccess
    }

    static func load(account: String, service: String) -> Data? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: account,
            kSecAttrService: service,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }
}

/// DPoP (RFC 9449) proof construction for the iLightShow API.
enum IlsDPoP {
    /// Base64url without padding (RFC 7515 §2).
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func sha256Base64URL(_ data: Data) -> String {
        base64URL(Data(SHA256.hash(data: data)))
    }

    /// Builds a DPoP proof JWT (ES256), mirroring `C0679t` in the APK:
    /// header `{typ, alg, jwk}`, payload `{htm, htu, iat, jti, nonce, ath?}`,
    /// signed over `b64url(header).b64url(payload)`.
    static func proof(
        key: IlsDPoPKey,
        method: String,
        url: String,
        nonce: String,
        accessToken: String? = nil
    ) throws -> String {
        let header = "{\"typ\":\"dpop+jwt\",\"alg\":\"ES256\"," + key.jwkFragment + "}"
        var payload = "\"htm\":\"\(method)\",\"htu\":\"\(url)\",\"iat\":\(Int(Date().timeIntervalSince1970)),\"jti\":\"\(UUID().uuidString)\",\"nonce\":\"\(nonce)\""
        if let token = accessToken {
            payload += ",\"ath\":\"\(sha256Base64URL(Data(token.utf8)))\""
        }
        let signingInput = base64URL(Data(header.utf8)) + "." + base64URL(Data("{\(payload)}".utf8))
        let signature = try key.sign(Data(signingInput.utf8))
        return signingInput + "." + base64URL(signature)
    }
}
