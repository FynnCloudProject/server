@testable import FynnCloudServer
import Foundation
import XCTest

final class LDAPTests: XCTestCase {
    func testFilterEscaping() {
        XCTAssertEqual(LDAPClient.escapeFilterValue("normal"), "normal")
        XCTAssertEqual(LDAPClient.escapeFilterValue("user*name"), "user\\2aname")
        XCTAssertEqual(LDAPClient.escapeFilterValue("user(name)"), "user\\28name\\29")
        XCTAssertEqual(LDAPClient.escapeFilterValue("user\\name"), "user\\5cname")
        XCTAssertEqual(LDAPClient.escapeFilterValue("user\0name"), "user\\00name")
        XCTAssertEqual(
            LDAPClient.escapeFilterValue("admin\\*(test)\0"),
            "admin\\5c\\2a\\28test\\29\\00"
        )
    }

    func testGroupNameExtraction() {
        XCTAssertEqual(
            LDAPClient.groupName(fromDN: "CN=GG-FynnCloud-Users,OU=Groups,DC=example,DC=com"),
            "GG-FynnCloud-Users"
        )
        XCTAssertEqual(
            LDAPClient.groupName(fromDN: "cn=developers,ou=groups,dc=example,dc=org"),
            "developers"
        )
        XCTAssertEqual(
            LDAPClient.groupName(fromDN: "OU=Engineering,DC=example,DC=org"),
            "Engineering"
        )
        XCTAssertNil(LDAPClient.groupName(fromDN: ""))
        XCTAssertNil(LDAPClient.groupName(fromDN: "invalid-dn"))
    }

    func testDNNormalization() {
        XCTAssertEqual(
            LDAPClient.normalizeDN("CN=Alex Miller, OU=Users , DC=example, DC=com"),
            "cn=alex miller,ou=users,dc=example,dc=com"
        )
    }

    func testDiscoveryFilter() {
        let adFilter = "(&(objectCategory=group)(|(cn=GG-FynnCloud-Users)(cn=GG-FynnCloud-Admins))(member:1.2.840.113556.1.4.1941:={userDN}))"
        XCTAssertEqual(
            LDAPClient.discoveryFilter(from: adFilter),
            "(|(objectCategory=group)(objectClass=group)(objectClass=groupOfNames)(objectClass=posixGroup)(objectClass=groupOfUniqueNames)(member=*)(uniqueMember=*)(memberUid=*))"
        )

        let openLdapFilter = "(&(objectClass=groupOfNames)(member={userDN}))"
        XCTAssertEqual(
            LDAPClient.discoveryFilter(from: openLdapFilter),
            "(|(objectCategory=group)(objectClass=group)(objectClass=groupOfNames)(objectClass=posixGroup)(objectClass=groupOfUniqueNames)(member=*)(uniqueMember=*)(memberUid=*))"
        )

        let staticFilter = "(|(cn=GG-FynnCloud-Users)(cn=GG-FynnCloud-Admins))"
        XCTAssertEqual(
            LDAPClient.discoveryFilter(from: staticFilter),
            staticFilter
        )

        XCTAssertEqual(
            LDAPClient.discoveryFilter(from: nil),
            "(|(objectCategory=group)(objectClass=group)(objectClass=groupOfNames)(objectClass=posixGroup)(objectClass=groupOfUniqueNames)(member=*)(uniqueMember=*)(memberUid=*))"
        )
    }

    func testFormatObjectGUID() {
        let rawBytes: [UInt8] = [
            0x23, 0x0f, 0xd9, 0xa8,
            0x44, 0x8c,
            0xe0, 0x48,
            0xa7, 0x8b,
            0x3e, 0x5e, 0x54, 0xc8, 0x61, 0x21
        ]
        let data = Data(rawBytes)
        let formatted = LDAPEntry.formatObjectGUID(data)
        XCTAssertEqual(formatted, "a8d90f23-8c44-48e0-a78b-3e5e54c86121")
    }

    func testActiveDirectoryEntryResolution() {
        let rawGuidBytes: [UInt8] = [
            0x01, 0x02, 0x03, 0x04,
            0x05, 0x06,
            0x07, 0x08,
            0x09, 0x0a,
            0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10
        ]
        let entry = LDAPEntry(
            dn: "CN=Alex Miller,OU=Users,DC=example,DC=com",
            attributes: [
                "samaccountname": [Data("alex.miller".utf8)],
                "userprincipalname": [Data("alex.miller@example.com".utf8)],
                "mail": [Data("alex.miller@example.com".utf8)],
                "displayname": [Data("Alex Miller".utf8)],
                "objectguid": [Data(rawGuidBytes)],
                "memberof": [
                    Data("CN=GG-FynnCloud-Admins,OU=Groups,DC=example,DC=com".utf8),
                    Data("CN=GG-FynnCloud-Users,OU=Groups,DC=example,DC=com".utf8),
                ]
            ]
        )

        let config = LDAPProviderConfig(
            enabled: true,
            host: "dc1.example.com",
            port: 636,
            useSSL: true,
            baseDN: "DC=example,DC=com",
            bindDN: nil,
            bindPassword: nil,
            userFilter: "(&(objectClass=user)(sAMAccountName={username}))",
            groupBaseDN: nil,
            groupFilter: nil,
            treatEmailAsVerified: true,
            uuidAttribute: "auto"
        )

        XCTAssertEqual(entry.resolveUsername(), "alex.miller")
        XCTAssertEqual(entry.resolveEmail(), "alex.miller@example.com")
        XCTAssertEqual(entry.resolveDisplayName(fallbackUsername: "alex.miller"), "Alex Miller")
        XCTAssertEqual(entry.resolveSubject(config: config), "04030201-0605-0807-090a-0b0c0d0e0f10")
        XCTAssertEqual(
            entry.directGroupDNs().compactMap { LDAPClient.groupName(fromDN: $0) },
            ["GG-FynnCloud-Admins", "GG-FynnCloud-Users"]
        )
    }

    func testOpenLDAPEntryResolution() {
        let entryUUID = "c3a7b7a2-1234-4567-89ab-cdef01234567"
        let entry = LDAPEntry(
            dn: "uid=sarah.connor,ou=engineering,dc=example,dc=org",
            attributes: [
                "uid": [Data("sarah.connor".utf8)],
                "mail": [Data("sarah.connor@example.org".utf8)],
                "givenname": [Data("Sarah".utf8)],
                "sn": [Data("Connor".utf8)],
                "entryuuid": [Data(entryUUID.utf8)],
                "memberof": [
                    Data("cn=engineers,ou=groups,dc=example,dc=org".utf8)
                ]
            ]
        )

        let config = LDAPProviderConfig(
            enabled: true,
            host: "localhost",
            port: 389,
            useSSL: false,
            baseDN: "dc=example,dc=org",
            bindDN: nil,
            bindPassword: nil,
            userFilter: "(uid={username})",
            groupBaseDN: nil,
            groupFilter: nil,
            treatEmailAsVerified: true,
            uuidAttribute: "auto"
        )

        XCTAssertEqual(entry.resolveUsername(), "sarah.connor")
        XCTAssertEqual(entry.resolveEmail(), "sarah.connor@example.org")
        XCTAssertEqual(entry.resolveDisplayName(fallbackUsername: "sarah.connor"), "Sarah Connor")
        XCTAssertEqual(entry.resolveSubject(config: config), entryUUID)
        XCTAssertEqual(
            entry.directGroupDNs().compactMap { LDAPClient.groupName(fromDN: $0) },
            ["engineers"]
        )
    }
}
