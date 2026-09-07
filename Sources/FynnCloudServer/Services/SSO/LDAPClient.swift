import Foundation
import Vapor

#if canImport(CLDAPShim)
import CLDAPShim
#endif

/// A normalized LDAP entry containing its DN and all returned attributes as raw byte arrays.
struct LDAPEntry: Sendable {
    let dn: String
    /// Lowercased attribute name -> array of raw values.
    let attributes: [String: [Data]]

    init(dn: String, attributes: [String: [Data]]) {
        self.dn = dn
        self.attributes = attributes
    }

    /// Decodes all string values for an attribute (UTF-8 preferred, falling back to ASCII/ISO-8859-1).
    func stringValues(for attribute: String) -> [String] {
        guard let values = attributes[attribute.lowercased()] else { return [] }
        return values.compactMap { data in
            String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii)
        }
    }

    /// Returns the first non-empty string value for an attribute.
    func stringValue(for attribute: String) -> String? {
        stringValues(for: attribute).first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    /// Returns the first raw data value for an attribute.
    func dataValue(for attribute: String) -> Data? {
        attributes[attribute.lowercased()]?.first
    }

    /// Resolves the user's login username across OpenLDAP (`uid`), Active Directory (`sAMAccountName`, `userPrincipalName`), and fallbacks (`cn`).
    func resolveUsername(fallback: String? = nil) -> String {
        if let uid = stringValue(for: "uid"), !uid.isEmpty { return uid }
        if let sam = stringValue(for: "sAMAccountName"), !sam.isEmpty { return sam }
        if let upn = stringValue(for: "userPrincipalName"), !upn.isEmpty {
            return upn
        }
        if let cn = stringValue(for: "cn"), !cn.isEmpty { return cn }
        if let fallback, !fallback.isEmpty { return fallback }
        return dn
    }

    /// Resolves the user's email address from `mail` or `userPrincipalName` (if formatted like an email).
    func resolveEmail() -> String? {
        if let mail = stringValue(for: "mail"), !mail.isEmpty {
            return mail.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let upn = stringValue(for: "userPrincipalName"), upn.contains("@") {
            return upn.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// Resolves the user's display name from `displayName`, `name`, `cn`, or `givenName` + `sn`.
    func resolveDisplayName(fallbackUsername: String) -> String {
        if let name = stringValue(for: "displayName"), !name.isEmpty { return name }
        if let name = stringValue(for: "name"), !name.isEmpty { return name }
        if let cn = stringValue(for: "cn"), !cn.isEmpty { return cn }
        let gn = stringValue(for: "givenName")
        let sn = stringValue(for: "sn")
        if let gn, let sn, !gn.isEmpty, !sn.isEmpty {
            return "\(gn) \(sn)"
        }
        if let gn, !gn.isEmpty { return gn }
        return fallbackUsername
    }

    /// Resolves the immutable subject ID used for identity linking.
    /// Honors `config.uuidAttribute` ("auto", "objectguid", "entryuuid", "ipauniqueid", "nsuniqueid", or custom).
    func resolveSubject(config: LDAPProviderConfig) -> String {
        func clean(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty == false) ? trimmed : nil
        }

        let requested = config.uuidAttribute.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let auto = requested.isEmpty || requested == "auto"
        let order = auto ? ["objectguid", "entryuuid", "ipauniqueid", "nsuniqueid", "guid"] : [requested]

        for attribute in order {
            switch attribute {
            case "objectguid":
                if let data = dataValue(for: "objectguid"), data.count == 16 {
                    return Self.formatObjectGUID(data)
                }
                if let str = clean(stringValue(for: "objectguid")) {
                    return str
                }
            case "entryuuid":
                if let str = clean(stringValue(for: "entryuuid")) { return str }
            case "ipauniqueid":
                if let str = clean(stringValue(for: "ipauniqueid")) { return str }
            case "nsuniqueid":
                if let str = clean(stringValue(for: "nsuniqueid")) { return str }
            case "guid":
                if let data = dataValue(for: "guid"), data.count == 16 {
                    return Self.formatObjectGUID(data)
                }
                if let str = clean(stringValue(for: "guid")) { return str }
            default:
                if let str = clean(stringValue(for: attribute)) { return str }
            }
        }
        return dn
    }

    /// Formats Active Directory's binary 16-byte `objectGUID` (mixed-endian) into its canonical UUID string.
    static func formatObjectGUID(_ data: Data) -> String {
        let bytes = [UInt8](data)
        guard bytes.count == 16 else {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        func hex(_ indices: [Int]) -> String {
            indices.map { String(format: "%02x", bytes[$0]) }.joined()
        }
        return [
            hex([3, 2, 1, 0]),
            hex([5, 4]),
            hex([7, 6]),
            hex([8, 9]),
            hex([10, 11, 12, 13, 14, 15]),
        ].joined(separator: "-").lowercased()
    }

    /// Returns direct group DNs from the user's `memberOf` attributes.
    func directGroupDNs() -> [String] {
        stringValues(for: "memberOf")
    }
}

/// A native, thread-safe LDAP client interacting directly with OpenLDAP C libraries via CLDAPShim.
/// Works uniformly across Microsoft Active Directory, OpenLDAP, FreeIPA, and 389 Directory Server.
final class LDAPClient {
    struct LDAPError: Error, LocalizedError, CustomStringConvertible {
        let code: Int32
        let message: String

        init(code: Int32, message: String? = nil) {
            self.code = code
            #if canImport(CLDAPShim)
            if let message {
                self.message = message
            } else if let cStr = ldap_err2string(code) {
                self.message = String(cString: cStr)
            } else {
                self.message = "LDAP error \(code)"
            }
            #else
            self.message = message ?? "LDAP error \(code)"
            #endif
        }

        var description: String {
            "[LDAPError] \(message) (code: \(code))"
        }

        var errorDescription: String? { description }
    }

    enum SearchScope: Int32 {
        case base = 0      // LDAP_SCOPE_BASE
        case oneLevel = 1  // LDAP_SCOPE_ONELEVEL
        case subtree = 2   // LDAP_SCOPE_SUBTREE
    }

    #if canImport(CLDAPShim)
    private var ld: OpaquePointer?
    #endif

    init(config: LDAPProviderConfig) throws {
        #if canImport(CLDAPShim)
        let scheme = config.useSSL ? "ldaps" : "ldap"
        let port = config.port ?? (config.useSSL ? 636 : 389)
        let uri = "\(scheme)://\(config.host):\(port)"

        var handle: OpaquePointer?
        let initRC = ldap_initialize(&handle, uri)
        guard initRC == 0, let handle else {
            throw LDAPError(code: initRC, message: "Failed to initialize LDAP connection to \(uri)")
        }
        self.ld = handle

        // 1. Set protocol version 3
        var version: Int32 = 3  // LDAP_VERSION3
        _ = withUnsafeMutablePointer(to: &version) {
            ldap_set_option(handle, 0x0011 /* LDAP_OPT_PROTOCOL_VERSION */, $0)
        }

        // 2. Disable referrals (essential for Active Directory compatibility)
        var referrals: Int32 = 0  // LDAP_OPT_OFF
        _ = withUnsafeMutablePointer(to: &referrals) {
            ldap_set_option(handle, 0x0008 /* LDAP_OPT_REFERRALS */, $0)
        }

        // 3. Set network timeout (10 seconds)
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        _ = withUnsafeMutablePointer(to: &tv) {
            ldap_set_option(handle, 0x5005 /* LDAP_OPT_NETWORK_TIMEOUT */, $0)
        }
        #else
        throw LDAPError(code: -1, message: "CLDAPShim is not available on this platform")
        #endif
    }

    deinit {
        close()
    }

    func close() {
        #if canImport(CLDAPShim)
        if let ld {
            ldap_unbind_ext_s(ld, nil, nil)
            self.ld = nil
        }
        #endif
    }

    /// Authenticates / binds to the LDAP server using SASL simple bind.
    func bind(dn: String?, password: String?) throws {
        #if canImport(CLDAPShim)
        guard let ld else {
            throw LDAPError(code: -1, message: "LDAP connection is closed")
        }

        if let dn, let password, !dn.isEmpty, !password.isEmpty {
            let pw = strdup(password)
            defer { free(pw) }
            var cred = berval(bv_len: numericCast(password.utf8.count), bv_val: pw)
            let rc = ldap_sasl_bind_s(ld, dn, nil, &cred, nil, nil, nil)
            guard rc == 0 else {
                throw LDAPError(code: rc)
            }
        } else {
            // Anonymous bind
            var cred = berval(bv_len: 0, bv_val: nil)
            let rc = ldap_sasl_bind_s(ld, nil, nil, &cred, nil, nil, nil)
            guard rc == 0 else {
                throw LDAPError(code: rc)
            }
        }
        #else
        throw LDAPError(code: -1, message: "CLDAPShim is not available on this platform")
        #endif
    }

    /// Searches the directory for entries matching the given filter and scope.
    func search(
        baseDN: String,
        scope: SearchScope = .subtree,
        filter: String,
        attributes: [String]? = nil
    ) throws -> [LDAPEntry] {
        #if canImport(CLDAPShim)
        guard let ld else {
            throw LDAPError(code: -1, message: "LDAP connection is closed")
        }

        let trimmedBase = baseDN.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBase.isEmpty else { return [] }

        var res: OpaquePointer?
        let searchRC: Int32 = {
            if let attributes, !attributes.isEmpty {
                var cStrings = attributes.map { strdup($0) }
                cStrings.append(nil)
                defer {
                    for ptr in cStrings where ptr != nil {
                        free(ptr)
                    }
                }
                return cStrings.withUnsafeMutableBufferPointer { buf in
                    ldap_search_ext_s(
                        ld, trimmedBase, scope.rawValue, filter,
                        buf.baseAddress, 0, nil, nil, nil, 0, &res
                    )
                }
            } else {
                // Return all user attributes and operational attributes
                var attrs: [UnsafeMutablePointer<CChar>?] = [strdup("*"), strdup("+"), nil]
                defer {
                    free(attrs[0])
                    free(attrs[1])
                }
                return attrs.withUnsafeMutableBufferPointer { buf in
                    ldap_search_ext_s(
                        ld, trimmedBase, scope.rawValue, filter,
                        buf.baseAddress, 0, nil, nil, nil, 0, &res
                    )
                }
            }
        }()

        if searchRC != 0 && attributes == nil {
            // Fallback for servers that reject "+" in requested attribute list
            let retryRC = ldap_search_ext_s(
                ld, trimmedBase, scope.rawValue, filter,
                nil, 0, nil, nil, nil, 0, &res
            )
            guard retryRC == 0, let res else {
                throw LDAPError(code: retryRC)
            }
            return try parseResults(res: res)
        }

        guard searchRC == 0, let res else {
            throw LDAPError(code: searchRC)
        }
        return try parseResults(res: res)
        #else
        throw LDAPError(code: -1, message: "CLDAPShim is not available on this platform")
        #endif
    }

    #if canImport(CLDAPShim)
    private func parseResults(res: OpaquePointer) throws -> [LDAPEntry] {
        guard let ld else { return [] }
        defer { ldap_msgfree(res) }

        var entries: [LDAPEntry] = []
        var entryPtr = ldap_first_entry(ld, res)
        while let entry = entryPtr {
            guard let dnC = ldap_get_dn(ld, entry) else {
                entryPtr = ldap_next_entry(ld, entry)
                continue
            }
            let dn = String(cString: dnC)
            ldap_memfree(dnC)

            var attributes: [String: [Data]] = [:]
            var ber: OpaquePointer?
            var attrC = ldap_first_attribute(ld, entry, &ber)
            while let attr = attrC {
                let attrName = String(cString: attr).lowercased()
                ldap_memfree(attr)

                if let values = ldap_get_values_len(ld, entry, attrName) {
                    let count = ldap_count_values_len(values)
                    var attrValues: [Data] = []
                    attrValues.reserveCapacity(Int(count))
                    for i in 0..<Int(count) {
                        if let bervalPtr = values[i], bervalPtr.pointee.bv_len > 0,
                            let valPtr = bervalPtr.pointee.bv_val
                        {
                            let data = Data(bytes: valPtr, count: Int(bervalPtr.pointee.bv_len))
                            attrValues.append(data)
                        }
                    }
                    ldap_value_free_len(values)
                    attributes[attrName] = attrValues
                }

                attrC = ldap_next_attribute(ld, entry, ber)
            }
            if let ber {
                ber_free(ber, 0)
            }

            entries.append(LDAPEntry(dn: dn, attributes: attributes))
            entryPtr = ldap_next_entry(ld, entry)
        }
        return entries
    }
    #endif

    // MARK: - Utilities

    /// Extracts the leftmost RDN attribute value from a DN, e.g. `cn=admins,ou=groups,...` -> `admins`.
    static func groupName(fromDN dn: String) -> String? {
        guard let firstRDN = dn.split(separator: ",", maxSplits: 1).first else { return nil }
        let parts = firstRDN.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let value = parts[1].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// Normalizes a DN (lowercased, uniform comma separation).
    static func normalizeDN(_ dn: String) -> String {
        dn.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: ",")
            .lowercased()
    }

    /// Escapes RFC 4515 filter metacharacters to prevent LDAP injection.
    static func escapeFilterValue(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\5c"
            case "*": escaped += "\\2a"
            case "(": escaped += "\\28"
            case ")": escaped += "\\29"
            case "\u{0000}": escaped += "\\00"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }

    /// Derives a global group discovery filter from the configured group filter.
    static func discoveryFilter(from configured: String?) -> String {
        guard let configured else {
            return "(|(objectCategory=group)(objectClass=group)(objectClass=groupOfNames)(objectClass=posixGroup)(objectClass=groupOfUniqueNames)(member=*)(uniqueMember=*)(memberUid=*))"
        }

        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "(|(objectCategory=group)(objectClass=group)(objectClass=groupOfNames)(objectClass=posixGroup)(objectClass=groupOfUniqueNames)(member=*)(uniqueMember=*)(memberUid=*))"
        }

        if trimmed.contains("{userDN}") || trimmed.contains("{username}") {
            return "(|(objectCategory=group)(objectClass=group)(objectClass=groupOfNames)(objectClass=posixGroup)(objectClass=groupOfUniqueNames)(member=*)(uniqueMember=*)(memberUid=*))"
        }
        return trimmed
    }
}
