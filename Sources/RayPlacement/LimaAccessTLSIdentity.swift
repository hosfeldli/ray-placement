import CryptoKit
import Darwin
import Foundation
import Security

/// A private, opt-in network identity. The signing key never leaves Keychain.
enum LimaAccessTLSIdentity {
    struct Material {
        let identity: SecIdentity
        let certificatePEM: String
        let fingerprint: String
    }

    private static var suffix: String { LimaTestEnvironment.isEnabled ? ".test" : "" }
    private static var keyTag: Data { Data(("dev.liam.lima.access.network-key" + suffix).utf8) }
    private static var certificateLabel: String { "Lima Access Network TLS" + suffix }
    private static var certificateService: String { "dev.liam.lima.access.network-certificate" + suffix }

    static func availableAddresses() -> [String] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }
        var addresses = Set<String>()
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current {
            let interface = entry.pointee
            if let address = interface.ifa_addr,
               Int32(address.pointee.sa_family) == AF_INET,
               interface.ifa_flags & UInt32(IFF_UP) != 0,
               interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0 {
                let value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_addr
                }
                let octets = withUnsafeBytes(of: value.s_addr) { Array($0) }
                if isPrivateIPv4(octets) {
                    addresses.insert(octets.map(String.init).joined(separator: "."))
                }
            }
            current = interface.ifa_next
        }
        return addresses.sorted()
    }

    static func isPrivateIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { UInt8($0) }
        return parts.count == 4 && isPrivateIPv4(parts)
    }

    private static func isPrivateIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        return bytes[0] == 10
            || (bytes[0] == 172 && (16...31).contains(bytes[1]))
            || (bytes[0] == 192 && bytes[1] == 168)
            || (bytes[0] == 100 && (64...127).contains(bytes[1])) // Tailscale CGNAT
    }

    static func loadOrCreate(for address: String) throws -> Material {
        guard isPrivateIPv4(address), availableAddresses().contains(address) else {
            throw failure("Choose a current private LAN or Tailscale address.")
        }
        let key = try loadOrCreateKey()
        var certificate = loadCertificate(for: address)
        if certificate == nil {
            certificate = try issueCertificate(key: key, address: address)
            guard let certificate else { throw failure("The network certificate is unavailable.") }
            try storeCertificate(certificate, for: address)
        }
        guard let certificate else { throw failure("The network certificate is unavailable.") }
        var identity: SecIdentity?
        let result = SecIdentityCreateWithCertificate(nil, certificate, &identity)
        guard result == errSecSuccess, let identity else {
            throw failure("Could not pair the network certificate with its Keychain signing key.")
        }
        let der = SecCertificateCopyData(certificate) as Data
        let encoded = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pem = "-----BEGIN CERTIFICATE-----\n" + encoded + "\n-----END CERTIFICATE-----\n"
        let fingerprint = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
        return Material(identity: identity, certificatePEM: pem, fingerprint: fingerprint)
    }

    private static func loadOrCreateKey() throws -> SecKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let key = item as! SecKey? {
            return key
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: keyTag,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw failure("Could not create a Keychain-backed network signing key.")
        }
        return key
    }

    private static func loadCertificate(for address: String) -> SecCertificate? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: certificateService,
            kSecAttrAccount as String: address,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return SecCertificateCreateWithData(nil, data as CFData)
    }

    private static func storeCertificate(_ certificate: SecCertificate, for address: String) throws {
        // Security may derive a different certificate label from its subject, so
        // persist the exact DER under a transport-specific Keychain account too.
        let certificateQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: certificateLabel,
            kSecValueRef as String: certificate
        ]
        let certificateResult = SecItemAdd(certificateQuery as CFDictionary, nil)
        guard certificateResult == errSecSuccess || certificateResult == errSecDuplicateItem else {
            throw failure("Could not store the network certificate in Keychain.")
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: certificateService,
            kSecAttrAccount as String: address
        ]
        SecItemDelete(query as CFDictionary)
        let attributes = query.merging([
            kSecValueData as String: SecCertificateCopyData(certificate) as Data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]) { _, new in new }
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
            throw failure("Could not persist the network certificate in Keychain.")
        }
    }

    private static func issueCertificate(key: SecKey, address: String) throws -> SecCertificate {
        guard let publicKey = SecKeyCopyPublicKey(key) else { throw failure("The network public key is unavailable.") }
        var error: Unmanaged<CFError>?
        guard let publicBytes = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?,
              publicBytes.count == 65, publicBytes.first == 4 else {
            throw failure("The network public key could not be encoded.")
        }
        let ecdsaSHA256 = derSequence([derOID([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02])])
        let ecPublicKey = derSequence([
            derOID([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]),
            derOID([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
        ])
        let name = derSequence([der(0x31, derSequence([
            derOID([0x55, 0x04, 0x03]), der(0x0C, Data("Lima Access".utf8))
        ]))])
        var serial = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial) == errSecSuccess else {
            throw failure("Could not create a certificate serial number.")
        }
        serial[0] &= 0x7F
        let now = Date()
        let validity = derSequence([
            der(0x17, Data(utcTime(now.addingTimeInterval(-3_600)).utf8)),
            der(0x17, Data(utcTime(now.addingTimeInterval(365 * 24 * 3_600)).utf8))
        ])
        let ip = address.split(separator: ".").compactMap { UInt8($0) }
        let altNames = derSequence([der(0x87, Data(ip))])
        let extensions = derSequence([
            derSequence([
                derOID([0x55, 0x1D, 0x11]), der(0x04, altNames)
            ]),
            derSequence([
                derOID([0x55, 0x1D, 0x13]), der(0x01, Data([0xFF])),
                der(0x04, derSequence([]))
            ]),
            derSequence([
                derOID([0x55, 0x1D, 0x25]),
                der(0x04, derSequence([derOID([0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01])]))
            ])
        ])
        let subjectPublicKey = derSequence([ecPublicKey, der(0x03, Data([0]) + publicBytes)])
        let tbs = derSequence([
            der(0xA0, der(0x02, Data([2]))), der(0x02, Data(serial)),
            ecdsaSHA256, name, validity, name, subjectPublicKey, der(0xA3, extensions)
        ])
        guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256,
                                                    tbs as CFData, &error) as Data? else {
            throw failure("Could not sign the network certificate.")
        }
        let certificateData = derSequence([tbs, ecdsaSHA256, der(0x03, Data([0]) + signature)])
        guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData) else {
            throw failure("Could not parse the generated network certificate.")
        }
        return certificate
    }

    private static func utcTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return formatter.string(from: date)
    }

    private static func derSequence(_ parts: [Data]) -> Data { der(0x30, parts.reduce(Data(), +)) }
    private static func derOID(_ bytes: [UInt8]) -> Data { der(0x06, Data(bytes)) }
    private static func der(_ tag: UInt8, _ content: Data) -> Data {
        let count = content.count
        let length: Data
        if count < 128 {
            length = Data([UInt8(count)])
        } else if count <= 255 {
            length = Data([0x81, UInt8(count)])
        } else {
            length = Data([0x82, UInt8((count >> 8) & 0xFF), UInt8(count & 0xFF)])
        }
        return Data([tag]) + length + content
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "LimaAccessTLS", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
