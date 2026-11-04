// Print the Sparkle (EdDSA) public key of a private key file, as SUPublicEDKey spells it.
// scripts/release.sh uses it in GitHub Actions, where the key comes from a secret instead of
// the login keychain, to check before building that the key matches project.yml.
//
// Usage:  swift scripts/sparkle-public-key.swift <private-key-file>
//
// The file is what `generate_keys -x` exports: base64 of the 32-byte seed, or of Sparkle's
// older 96-byte form (64-byte expanded private key, then the 32-byte public key).

import CryptoKit
import Foundation

guard CommandLine.arguments.count == 2,
      let text = try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8),
      let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
    FileHandle.standardError.write(Data("usage: sparkle-public-key.swift <base64 private key file>\n".utf8))
    exit(2)
}

switch data.count {
case 32:
    guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else { exit(1) }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case 96:
    print(data.suffix(32).base64EncodedString())
default:
    FileHandle.standardError.write(Data("unexpected key length \(data.count) bytes\n".utf8))
    exit(1)
}
