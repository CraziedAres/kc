import Darwin
import Foundation
import KeychainKit

let usage = """
usage: kc [--service NAME] <command> [args]

commands:
  set <name> [value]           store a secret (prompts, or reads stdin, if value is omitted)
  get <name>                   print a secret
  list                         list secret names
  delete <name>                remove a secret
  gen [--force] <name> [length] store a random secret (default 32 letters and digits)
                               without showing it; --force replaces an existing one
  run <name[=VAR]>... -- <cmd> run cmd with secrets exported as env vars
                               (VAR defaults to the secret name)
  sync [--dry-run] <target> <name[=VAR]>... [-- <args>]
                               push secrets to a deploy host's secret store;
                               target is wrangler, vercel (default env:
                               production), gh or fly; <args> go to its CLI

  In run and sync, --all stands for every secret in the service.

options:
  --service NAME               keychain service to use (default: \(Keychain.defaultService),
                               or $KC_SERVICE if set)
"""

struct UsageError: Error, CustomStringConvertible {
    let description: String
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("kc: \(message)\n".utf8))
    exit(code)
}

/// Reads a secret without it touching argv or shell history: a hidden prompt
/// when attached to a terminal, otherwise everything on stdin.
func readSecret(for name: String) throws -> String {
    if isatty(STDIN_FILENO) != 0 {
        var buffer = [CChar](repeating: 0, count: 8192)
        guard readpassphrase("Value for \(name): ", &buffer, buffer.count, RPP_REQUIRE_TTY) != nil else {
            throw UsageError(description: "could not read from terminal")
        }
        defer { _ = buffer.withUnsafeMutableBufferPointer { memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        return String(cString: buffer)
    }
    let data = FileHandle.standardInput.readDataToEndOfFile()
    var value = String(decoding: data, as: UTF8.self)
    if value.hasSuffix("\n") { value.removeLast() }
    return value
}

func runCommand(_ args: [String], keychain: Keychain) throws -> Never {
    guard let separator = args.firstIndex(of: "--") else {
        throw UsageError(description: "run needs `--` before the command")
    }
    let specs = args[..<separator]
    let command = Array(args[(separator + 1)...])
    guard !command.isEmpty else { throw UsageError(description: "run needs a command after `--`") }

    for spec in try SecretSpec.parse(specs, keychain: keychain) {
        setenv(spec.variable, try spec.value(from: keychain), 1)
    }

    var argv = command.map { strdup($0) }
    argv.append(nil)
    execvp(command[0], argv)
    fail("\(command[0]): \(String(cString: strerror(errno)))", code: 127)
}

func main() throws {
    var args = Array(CommandLine.arguments.dropFirst())
    var service = ProcessInfo.processInfo.environment["KC_SERVICE"] ?? Keychain.defaultService

    if args.first == "--service" {
        guard args.count >= 2 else { throw UsageError(description: "--service needs a value") }
        service = args[1]
        args.removeFirst(2)
    }

    guard let command = args.first else {
        print(usage)
        exit(2)
    }
    args.removeFirst()
    let keychain = Keychain(service: service)

    switch (command, args.count) {
    case ("set", 1):
        try keychain.set(args[0], value: try readSecret(for: args[0]))
    case ("set", 2):
        try keychain.set(args[0], value: args[1])
    case ("get", 1):
        guard let value = try keychain.get(args[0]) else {
            fail("no secret named '\(args[0])'")
        }
        // Skip the trailing newline when piped so `kc get x | pbcopy` is exact.
        print(value, terminator: isatty(STDOUT_FILENO) != 0 ? "\n" : "")
    case ("list", 0), ("ls", 0):
        try keychain.list().forEach { print($0) }
    case ("delete", 1), ("rm", 1):
        guard try keychain.delete(args[0]) else { fail("no secret named '\(args[0])'") }
    case ("run", _):
        try runCommand(args, keychain: keychain)
    case ("gen", _):
        try genCommand(args, keychain: keychain)
    case ("sync", _):
        try syncCommand(args, keychain: keychain)
    case ("help", _), ("-h", _), ("--help", _):
        print(usage)
    default:
        throw UsageError(description: "bad arguments\n\n\(usage)")
    }
}

do {
    try main()
} catch let error as UsageError {
    fail(error.description, code: 2)
} catch {
    fail("\(error)")
}
