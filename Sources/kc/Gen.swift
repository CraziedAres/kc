import Foundation
import KeychainKit
import Security

/// Letters and digits only, so generated secrets are safe in env vars, URLs,
/// shell commands and config files without quoting.
private let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".utf8)

/// A random string from `alphabet`, using the system CSPRNG. Bytes past the
/// largest multiple of the alphabet size are discarded so every character is
/// equally likely.
func randomSecret(length: Int) throws -> String {
    let limit = UInt8(256 - 256 % alphabet.count)
    var result: [UInt8] = []
    result.reserveCapacity(length)

    var bytes = [UInt8](repeating: 0, count: 64)
    while result.count < length {
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw KeychainError(status: errSecAllocate)
        }
        for byte in bytes where byte < limit && result.count < length {
            result.append(alphabet[Int(byte) % alphabet.count])
        }
    }
    return String(decoding: result, as: UTF8.self)
}

func genCommand(_ args: [String], keychain: Keychain) throws {
    var args = args
    let force = args.first == "--force"
    if force { args.removeFirst() }

    guard (1...2).contains(args.count) else {
        throw UsageError(description: "usage: kc gen [--force] <name> [length]")
    }
    let name = args[0]
    let length = args.count == 2 ? Int(args[1]) : 32
    guard let length, (8...4096).contains(length) else {
        throw UsageError(description: "length must be a number from 8 to 4096")
    }

    // Checked via list() so an existing secret is never read just to test for it.
    if !force, try keychain.list().contains(name) {
        throw UsageError(description: "'\(name)' already exists; use --force to replace it")
    }

    try keychain.set(name, value: try randomSecret(length: length))
    FileHandle.standardError.write(Data("kc: stored a random \(length)-character secret as \(name)\n".utf8))
}
