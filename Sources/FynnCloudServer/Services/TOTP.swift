import Crypto
import Foundation

/// RFC 6238 Time-based One-Time Password helpers (SHA1, 6 digits, 30s period) plus
/// the base32 secret handling and recovery-code utilities used by the 2FA flow.
enum TOTP {
    static let digits = 6
    static let period = 30
    /// A ±1 step tolerance absorbs clock drift between server and authenticator.
    static let windowSteps = 1
    private static let secretByteCount = 20  // 160-bit, recommended for HOTP/TOTP

    // MARK: - Secret generation

    /// A fresh random base32-encoded shared secret suitable for an authenticator app.
    static func generateSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: secretByteCount)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return base32Encode(Data(bytes))
    }

    /// The `otpauth://` provisioning URI encoded into the setup QR code.
    static func provisioningURI(secret: String, account: String, issuer: String) -> String {
        let label = "\(issuer):\(account)"
        var components = URLComponents()
        components.scheme = "otpauth"
        components.host = "totp"
        components.percentEncodedPath = "/" + urlEncode(label)
        components.queryItems = [
            URLQueryItem(name: "secret", value: secret),
            URLQueryItem(name: "issuer", value: issuer),
            URLQueryItem(name: "algorithm", value: "SHA1"),
            URLQueryItem(name: "digits", value: String(digits)),
            URLQueryItem(name: "period", value: String(period)),
        ]
        return components.string ?? "otpauth://totp/\(label)?secret=\(secret)"
    }

    // MARK: - Verification

    /// Validates a user-supplied code against the secret within the drift window.
    static func verify(code: String, secret: String, at date: Date = Date()) -> Bool {
        let normalized = code.filter { $0.isNumber }
        guard normalized.count == digits else { return false }

        let counter = Int64(date.timeIntervalSince1970) / Int64(period)
        for offset in -windowSteps...windowSteps {
            let step = counter + Int64(offset)
            guard step >= 0, let generated = generate(secret: secret, counter: UInt64(step))
            else { continue }
            if constantTimeEquals(generated, normalized) { return true }
        }
        return false
    }

    /// Generates the code for a specific 30s step counter.
    static func generate(secret: String, counter: UInt64) -> String? {
        guard let key = base32Decode(secret) else { return nil }
        var bigEndianCounter = counter.bigEndian
        let counterData = withUnsafeBytes(of: &bigEndianCounter) { Data($0) }

        let mac = HMAC<Insecure.SHA1>.authenticationCode(
            for: counterData, using: SymmetricKey(data: key))
        let hash = Data(mac)

        let dynamicOffset = Int(hash[hash.count - 1] & 0x0f)
        let binary =
            (UInt32(hash[dynamicOffset] & 0x7f) << 24)
            | (UInt32(hash[dynamicOffset + 1]) << 16)
            | (UInt32(hash[dynamicOffset + 2]) << 8)
            | UInt32(hash[dynamicOffset + 3])

        let modulus = UInt32(pow(10.0, Double(digits)))
        return String(format: "%0\(digits)d", Int(binary % modulus))
    }

    // MARK: - Recovery codes

    /// Generates human-friendly recovery codes ("abcd-efgh"). The plaintext is shown to the user
    /// exactly once; callers hash it (bcrypt) before persisting.
    static func generateRecoveryCodes(count: Int = 10) -> [String] {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var plaintext: [String] = []
        for _ in 0..<count {
            var raw = ""
            for position in 0..<8 {
                if position == 4 { raw += "-" }
                raw.append(alphabet[Int.random(in: 0..<alphabet.count)])
            }
            plaintext.append(raw)
        }
        return plaintext
    }

    /// Normalizes a recovery code (case/format insensitive) so hashing and matching are stable.
    static func normalizeRecoveryCode(_ code: String) -> String {
        code.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: - Base32 (RFC 4648, no padding)

    private static let base32Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    static func base32Encode(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        var output = ""
        var buffer = 0
        var bitsLeft = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bitsLeft += 8
            while bitsLeft >= 5 {
                let index = (buffer >> (bitsLeft - 5)) & 0x1f
                bitsLeft -= 5
                output.append(base32Alphabet[index])
            }
        }
        if bitsLeft > 0 {
            let index = (buffer << (5 - bitsLeft)) & 0x1f
            output.append(base32Alphabet[index])
        }
        return output
    }

    static func base32Decode(_ string: String) -> Data? {
        let cleaned = string.uppercased().filter { $0 != "=" && !$0.isWhitespace }
        guard !cleaned.isEmpty else { return nil }
        var lookup: [Character: Int] = [:]
        for (index, char) in base32Alphabet.enumerated() { lookup[char] = index }

        var buffer = 0
        var bitsLeft = 0
        var bytes = [UInt8]()
        for char in cleaned {
            guard let value = lookup[char] else { return nil }
            buffer = (buffer << 5) | value
            bitsLeft += 5
            if bitsLeft >= 8 {
                bytes.append(UInt8((buffer >> (bitsLeft - 8)) & 0xff))
                bitsLeft -= 8
            }
        }
        return Data(bytes)
    }

    // MARK: - Helpers

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }

    private static func urlEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
