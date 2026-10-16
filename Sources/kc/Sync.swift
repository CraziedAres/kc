import Foundation
import KeychainKit

/// A secret to hand to another program: the Keychain name it's stored under
/// and the variable name the other side should see.
struct SecretSpec {
    let name: String
    let variable: String

    /// Parses `NAME` or `NAME=VAR`.
    init(_ spec: String) {
        let parts = spec.split(separator: "=", maxSplits: 1).map(String.init)
        name = parts[0]
        variable = parts.count == 2 ? parts[1] : parts[0]
    }

    func value(from keychain: Keychain) throws -> String {
        guard let value = try keychain.get(name) else {
            throw UsageError(description: "no secret named '\(name)'")
        }
        return value
    }
}

/// One invocation of a host's CLI. The secret travels on stdin only, never in
/// argv, so it can't show up in `ps` or in the tool's own logging of commands.
struct SyncStep {
    var arguments: [String]
    var input: String?
    /// Output hidden and failure ignored (e.g. removing a variable that may not exist yet).
    var bestEffort = false
}

enum SyncTarget: String, CaseIterable {
    case wrangler, vercel, gh, fly

    var tools: [String] {
        self == .fly ? ["fly", "flyctl"] : [rawValue]
    }

    /// `extra` is everything after `--`, passed through to the host's CLI.
    func steps(for secrets: [(SecretSpec, String)], extra: [String]) -> [SyncStep] {
        switch self {
        case .wrangler:
            return secrets.map { spec, value in
                SyncStep(arguments: ["secret", "put", spec.variable] + extra, input: value)
            }
        case .gh:
            return secrets.map { spec, value in
                SyncStep(arguments: ["secret", "set", spec.variable] + extra, input: value)
            }
        case .vercel:
            // `vercel env add` refuses names that already exist, so remove first.
            let environment = extra.isEmpty ? ["production"] : extra
            return secrets.flatMap { spec, value in [
                SyncStep(arguments: ["env", "rm", spec.variable] + environment + ["-y"], bestEffort: true),
                SyncStep(arguments: ["env", "add", spec.variable] + environment, input: value),
            ] }
        case .fly:
            // One import for all of them, so the app restarts once rather than per secret.
            let lines = secrets.map { spec, value in
                value.contains("\n") ? "\(spec.variable)=\"\"\"\n\(value)\n\"\"\"" : "\(spec.variable)=\(value)"
            }
            return [SyncStep(arguments: ["secrets", "import"] + extra, input: lines.joined(separator: "\n") + "\n")]
        }
    }
}

/// Finds a host CLI, preferring the project's own `node_modules/.bin` (where
/// wrangler and vercel usually live) over `$PATH`.
func findTool(_ names: [String]) -> URL? {
    let fileManager = FileManager.default
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    let dirs = [fileManager.currentDirectoryPath + "/node_modules/.bin"] + path.split(separator: ":").map(String.init)
    for name in names {
        for dir in dirs where fileManager.isExecutableFile(atPath: "\(dir)/\(name)") {
            return URL(fileURLWithPath: "\(dir)/\(name)")
        }
    }
    return nil
}

func syncCommand(_ args: [String], keychain: Keychain) throws {
    var args = args
    let dryRun = args.first == "--dry-run"
    if dryRun { args.removeFirst() }

    let targets = SyncTarget.allCases.map(\.rawValue).joined(separator: ", ")
    guard let first = args.first else { throw UsageError(description: "sync needs a target (\(targets))") }
    guard let target = SyncTarget(rawValue: first) else {
        throw UsageError(description: "unknown sync target '\(first)' (expected \(targets))")
    }
    args.removeFirst()

    let separator = args.firstIndex(of: "--") ?? args.endIndex
    let specs = args[..<separator].map(SecretSpec.init)
    let extra = separator < args.endIndex ? Array(args[(separator + 1)...]) : []
    guard !specs.isEmpty else { throw UsageError(description: "sync needs at least one secret name") }

    // Read every secret up front so a missing one fails before anything is pushed.
    let secrets = try specs.map { ($0, try $0.value(from: keychain)) }
    let steps = target.steps(for: secrets, extra: extra)

    if dryRun {
        for step in steps {
            let input = step.input == nil ? "" : "  < (secret on stdin)"
            print("\(target.tools[0]) \(step.arguments.joined(separator: " "))\(input)")
        }
        return
    }

    guard let tool = findTool(target.tools) else {
        throw UsageError(description: "\(target.tools[0]) not found in ./node_modules/.bin or $PATH")
    }

    for step in steps {
        let process = Process()
        process.executableURL = tool
        process.arguments = step.arguments
        let stdin = Pipe()
        process.standardInput = stdin
        if step.bestEffort {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }

        try process.run()
        if let input = step.input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
        }
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()

        if process.terminationStatus != 0 && !step.bestEffort {
            fail("\(tool.lastPathComponent) \(step.arguments.joined(separator: " ")) exited with \(process.terminationStatus)")
        }
    }

    let names = secrets.map(\.0.variable).joined(separator: ", ")
    FileHandle.standardError.write(Data("kc: synced \(names) to \(target.rawValue)\n".utf8))
}
