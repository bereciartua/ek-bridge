import Foundation
import Security

@main
struct SignedXPCBoundaryTests {
    static func main() {
        let requirement = SignedXPCBoundary.codeRequirement(
            identifier: "dev.martin.dot.eventkitbridge.client",
            leafSHA1: String(repeating: "a", count: 40))!
        precondition(SignedXPCBoundary.syntaxIsValid(requirement))
        precondition(requirement.contains("eventkitbridge.client"))
        precondition(SignedXPCBoundary.codeRequirement(
            identifier: "client\" or true", leafSHA1: String(repeating: "a", count: 40)) == nil)
        precondition(SignedXPCBoundary.codeRequirement(
            identifier: "dev.martin.client", leafSHA1: "short") == nil)
        precondition(!SignedXPCBoundary.syntaxIsValid("identifier \"unterminated"))
        precondition(CommandLine.arguments.count == 3)
        var identityRequirement: SecRequirement?
        precondition(SecRequirementCreateWithString(
            "identifier \"dev.martin.dot.eventkitbridge.client\"" as CFString,
            SecCSFlags(rawValue: 0), &identityRequirement) == errSecSuccess)
        precondition(matches(CommandLine.arguments[1], identityRequirement!))
        precondition(!matches(CommandLine.arguments[2], identityRequirement!))
        print("Signed XPC boundary: requirement syntax and wrong-client identity passed")
    }

    static func matches(_ path: String, _ requirement: SecRequirement) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL,
                                          SecCSFlags(rawValue: 0), &code) == errSecSuccess,
              let code else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: 0),
                                          requirement) == errSecSuccess
    }
}
