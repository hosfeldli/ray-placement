#!/usr/bin/env swift
// Run locally in Terminal. Never pass AMO credentials as command-line arguments.
import Foundation
import Security
import Darwin

let account = "lima-browser-bridge"
let services = ["com.lima.browser-bridge.amo-issuer", "com.lima.browser-bridge.amo-secret"]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func save(_ value: String, service: String) {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrAccount as String: account,
        kSecAttrService as String: service
    ]
    let data = Data(value.utf8)
    var result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if result == errSecItemNotFound {
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = service
        result = SecItemAdd(attributes as CFDictionary, nil)
    }
    guard result == errSecSuccess else {
        fail("Keychain storage failed (status \(result)). No credential values were logged.")
    }
}

if CommandLine.arguments.contains("--check") {
    print("AMO credential helper compiled. No Keychain entries were read or changed.")
    exit(0)
}
guard CommandLine.arguments.count == 1, isatty(STDIN_FILENO) == 1 else {
    fail("Run this helper directly in a local Terminal with no arguments. Never put secrets in chat.")
}
print("Create AMO API credentials in the Mozilla Add-ons Developer Hub first.")
print("Both prompts are hidden. Values are saved only to this Mac's Keychain.")
print("Existing Lima AMO entries will be replaced; press Control-C to cancel.")
guard let issuerPointer = getpass("AMO JWT issuer: ") else { fail("Input cancelled.") }
let issuer = String(cString: issuerPointer)
guard issuer.range(of: #"^user:[0-9]+:[0-9]+$"#, options: .regularExpression) != nil else {
    fail("Unexpected issuer format; nothing was saved.")
}
guard let secretPointer = getpass("AMO JWT secret: ") else { fail("Input cancelled.") }
let secret = String(cString: secretPointer)
guard secret.count >= 32, secret.count <= 4096,
      !secret.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) else {
    fail("Unexpected secret format; nothing was saved.")
}
save(issuer, service: services[0])
save(secret, service: services[1])
print("AMO credentials saved to Keychain. No submission, installation, or deployment occurred.")
