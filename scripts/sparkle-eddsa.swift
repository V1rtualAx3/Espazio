// EdDSA (Ed25519) keys and signatures for Sparkle updates, with CryptoKit (macOS).
//   swift scripts/sparkle-eddsa.swift generate <private-key-file>   writes the private key, prints the public key
//   swift scripts/sparkle-eddsa.swift public-key                     public key of $SPARKLE_ED_PRIVATE_KEY
//   swift scripts/sparkle-eddsa.swift sign <file>                    signature of <file> with $SPARKLE_ED_PRIVATE_KEY
// Keys are base64: the 32-byte private seed and the 32-byte public key (the SUPublicEDKey format).
// The private key is read from the environment, never from the command line.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func privateKeyFromEnvironment() -> Curve25519.Signing.PrivateKey {
    let encoded = (ProcessInfo.processInfo.environment["SPARKLE_ED_PRIVATE_KEY"] ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let seed = Data(base64Encoded: encoded), seed.count == 32,
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
        fail("SPARKLE_ED_PRIVATE_KEY is missing or is not a base64 32-byte Ed25519 key.")
    }
    return key
}

let arguments = CommandLine.arguments.dropFirst()
switch (arguments.first, arguments.dropFirst().first) {
case ("generate", let path?):
    guard !FileManager.default.fileExists(atPath: path) else { fail("\(path) already exists.") }
    let key = Curve25519.Signing.PrivateKey()
    guard FileManager.default.createFile(
        atPath: path, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
        attributes: [.posixPermissions: 0o600]) else { fail("Cannot write \(path).") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case ("public-key", nil):
    print(privateKeyFromEnvironment().publicKey.rawRepresentation.base64EncodedString())
case ("sign", let path?):
    guard let data = FileManager.default.contents(atPath: path) else { fail("Cannot read \(path).") }
    let key = privateKeyFromEnvironment()
    let signature = try key.signature(for: data)
    guard key.publicKey.isValidSignature(signature, for: data) else { fail("Signature check failed.") }
    print(signature.base64EncodedString())
default:
    fail("usage: sparkle-eddsa.swift generate <file> | public-key | sign <file>")
}
