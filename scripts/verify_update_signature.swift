// Checks an update archive's EdDSA signature against the public key the app
// ships (Info.plist SUPublicEDKey), as Sparkle does before installing. Run by
// release.sh after sign_update, so a release signed with a key that doesn't
// match the app's never reaches users: installed copies would refuse it.
//
// Usage: verify-update-signature PUBLIC_KEY_BASE64 FILE SIGNATURE_BASE64
import CryptoKit
import Foundation

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("verify-update-signature: \(message)\n".utf8))
    exit(code)
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    fail("usage: verify-update-signature PUBLIC_KEY_BASE64 FILE SIGNATURE_BASE64", code: 2)
}
guard let keyData = Data(base64Encoded: arguments[1]), keyData.count == 32,
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
    fail("the public key isn't a base64 Ed25519 key")
}
guard let signature = Data(base64Encoded: arguments[3]), signature.count == 64 else {
    fail("the signature isn't a base64 Ed25519 signature")
}
guard let file = FileManager.default.contents(atPath: arguments[2]) else {
    fail("can't read \(arguments[2])")
}
guard key.isValidSignature(signature, for: file) else {
    fail("\((arguments[2] as NSString).lastPathComponent)'s signature doesn't match SUPublicEDKey; was it signed with another key?")
}
print("verify-update-signature: \((arguments[2] as NSString).lastPathComponent) matches SUPublicEDKey")
