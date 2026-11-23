import CryptoKit
import Foundation
import Security

/// Errors from the DPoP key and proof machinery.
enum DPoPError: Error, Equatable {
    /// An unexpected Keychain status while loading the stored key (not a
    /// plain "item not found"), which must not be mistaken for "no key".
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
    static let keyAccount = "com.lumendesk.ilightshow.dpop.v1"
    static let service = "com.lumendesk.LumenDesk"

    private let privateKey: P256.Signing.PrivateKey
    private let jwkX: Data
    private let jwkY: Data

    /// Loads the persisted key when one exists, otherwise generates and
    /// stores a fresh one. A transient Keychain error (locked, ACL denial)
    /// is surfaced rather than treated as "no key", so the existing enrolled
    /// key is never silently replaced.
    convenience init() throws {
        if let stored = try IlsKeychain.loadStrict(account: Self.keyAccount, service: Self.service),
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

    /// The JWK as a dictionary, for the challenge body's `public_key` and the
    /// DPoP proof header.
    var jwkDictionary: [String: String] {
        ["kty": "EC", "crv": "P-256", "x": IlsDPoP.base64URL(jwkX), "y": IlsDPoP.base64URL(jwkY)]
    }

    /// RFC 7638 JWK thumbprint (SHA-256 over the canonical member set). Binds
    /// a persisted token to the key that enrolled it, so a token restored
    /// after the key was regenerated is discarded rather than used.
    var thumbprint: String {
        let canonical = "{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"\(IlsDPoP.base64URL(jwkX))\",\"y\":\"\(IlsDPoP.base64URL(jwkY))\"}"
        return IlsDPoP.sha256Base64URL(Data(canonical.utf8))
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

/// A minimal Keychain store for the DPoP key and the enrolment token.
///
/// Items are `ThisDeviceOnly` so the device-bound credential is not carried
/// to another device through an encrypted backup.
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
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ] as CFDictionary, nil) == errSecSuccess
    }

    static func delete(account: String, service: String) {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: account,
            kSecAttrService: service,
        ] as CFDictionary)
    }

    /// Returns the stored data, nil when the item is absent, or throws on an
    /// unexpected status so callers do not mistake a locked Keychain for a
    /// missing item (which would otherwise regenerate and overwrite the key).
    static func loadStrict(account: String, service: String) throws -> Data? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: account,
            kSecAttrService: service,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw DPoPError.keyImportFailed
        }
    }

    /// Best-effort load used where an absent or unreadable item is equally a
    /// "no credential" outcome (the token, which is simply re-fetched).
    static func load(account: String, service: String) -> Data? {
        (try? loadStrict(account: account, service: service)) ?? nil
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
    ///
    /// Header and payload are JSON-serialized (not string-interpolated) so a
    /// quote, backslash or control character in `url` or the server-supplied
    /// `nonce` cannot break the JSON or inject claims. Per RFC 9449 §4.2 the
    /// `htu` claim is the request URI with query and fragment removed.
    static func proof(
        key: IlsDPoPKey,
        method: String,
        url: String,
        nonce: String,
        accessToken: String? = nil
    ) throws -> String {
        let header: [String: Any] = [
            "typ": "dpop+jwt",
            "alg": "ES256",
            "jwk": key.jwkDictionary,
        ]
        var payload: [String: Any] = [
            "htm": method,
            "htu": htu(from: url),
            "iat": Int(Date().timeIntervalSince1970),
            "jti": UUID().uuidString,
            "nonce": nonce,
        ]
        if let accessToken {
            payload["ath"] = sha256Base64URL(Data(accessToken.utf8))
        }
        let signingInput = try base64URL(json(header)) + "." + base64URL(json(payload))
        let signature = try key.sign(Data(signingInput.utf8))
        return signingInput + "." + base64URL(signature)
    }

    /// The `htu` value: the URI without query or fragment (RFC 9449 §4.2).
    private static func htu(from url: String) -> String {
        guard var components = URLComponents(string: url) else { return url }
        components.query = nil
        components.fragment = nil
        return components.string ?? url
    }

    private static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
