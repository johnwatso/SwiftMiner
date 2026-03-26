import Foundation

struct CommandError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

struct ProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum ReleaseChannel: String {
    case stable
    case beta
}

struct PublisherArguments {
    var version: String
    var artifactPath: String
    var releaseNotesPath: String?
    var channel: ReleaseChannel
}

func usage() {
    let text = """
    Usage:
      SparklePublisher <version> <exported-app-or-zip> [release-notes-html] [--channel stable|beta]
      SparklePublisher --version <version> --artifact <exported-app-or-zip> [--release-notes <release-notes-html>] [--channel stable|beta]

    Example:
      ./scripts/publish_sparkle_release.sh 1.0.1 ~/Desktop/SwiftMiner.app docs/release-notes/1.0.1.html --channel beta

    Environment:
      SPARKLE_GENERATE_APPCAST   Optional absolute path to generate_appcast
      SPARKLE_PRIVATE_KEY_PATH   Optional Sparkle private key path for --ed-key-file
      SWIFTMINER_ROOT            Optional repo root override
    """
    print(text)
}

func parseArguments(_ rawArgs: [String]) throws -> PublisherArguments {
    var args = rawArgs
    var version = ""
    var artifactPath = ""
    var releaseNotesPath: String?
    var channel: ReleaseChannel = .stable

    if args.count >= 2, !args[0].hasPrefix("--") {
        version = args.removeFirst()
        artifactPath = args.removeFirst()
        if !args.isEmpty, !args[0].hasPrefix("--") {
            releaseNotesPath = args.removeFirst()
        }
    }

    while !args.isEmpty {
        let flag = args.removeFirst()
        switch flag {
        case "--version":
            guard !args.isEmpty else {
                throw CommandError(message: "Missing value for --version")
            }
            version = args.removeFirst()
        case "--artifact":
            guard !args.isEmpty else {
                throw CommandError(message: "Missing value for --artifact")
            }
            artifactPath = args.removeFirst()
        case "--release-notes":
            guard !args.isEmpty else {
                throw CommandError(message: "Missing value for --release-notes")
            }
            releaseNotesPath = args.removeFirst()
        case "--channel":
            guard !args.isEmpty else {
                throw CommandError(message: "Missing value for --channel")
            }
            guard let parsedChannel = ReleaseChannel(rawValue: args.removeFirst().lowercased()) else {
                throw CommandError(message: "Unsupported channel. Use --channel stable or --channel beta.")
            }
            channel = parsedChannel
        case "-h", "--help":
            usage()
            exit(0)
        default:
            throw CommandError(message: "Unknown argument: \(flag)")
        }
    }

    guard !version.isEmpty, !artifactPath.isEmpty else {
        usage()
        throw CommandError(message: "Invalid arguments.")
    }

    return PublisherArguments(
        version: version,
        artifactPath: artifactPath,
        releaseNotesPath: releaseNotesPath,
        channel: channel
    )
}

@discardableResult
func runProcess(
    _ executable: String,
    _ arguments: [String],
    cwd: URL? = nil,
    captureOutput: Bool = true,
    allowFailure: Bool = false,
    extraEnvironment: [String: String] = [:]
) throws -> ProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    if let cwd {
        process.currentDirectoryURL = cwd
    }

    if !extraEnvironment.isEmpty {
        var env = ProcessInfo.processInfo.environment
        for (key, value) in extraEnvironment {
            env[key] = value
        }
        process.environment = env
    }

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()

    if captureOutput {
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    do {
        try process.run()
    } catch {
        throw CommandError(message: "Failed to start \(executable): \(error.localizedDescription)")
    }

    process.waitUntilExit()

    let status = process.terminationStatus
    let stdoutData = captureOutput ? stdoutPipe.fileHandleForReading.readDataToEndOfFile() : Data()
    let stderrData = captureOutput ? stderrPipe.fileHandleForReading.readDataToEndOfFile() : Data()
    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
    let stderr = String(data: stderrData, encoding: .utf8) ?? ""

    if status != 0 && !allowFailure {
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty {
            throw CommandError(message: "Command failed (\(status)): \(executable) \(arguments.joined(separator: " "))")
        }
        throw CommandError(message: message)
    }

    return ProcessResult(status: status, stdout: stdout, stderr: stderr)
}

func findExecutable(named name: String) -> String? {
    if name.contains("/") {
        return FileManager.default.isExecutableFile(atPath: name) ? name : nil
    }

    let pathValue = ProcessInfo.processInfo.environment["PATH"] ?? ""
    let paths = pathValue.split(separator: ":").map(String.init)
    for path in paths {
        let candidate = URL(fileURLWithPath: path).appendingPathComponent(name).path
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }

    return nil
}

func expandedPath(_ raw: String) -> String {
    (raw as NSString).expandingTildeInPath
}

func absoluteURL(_ raw: String, relativeTo base: URL) -> URL {
    let expanded = expandedPath(raw)
    if expanded.hasPrefix("/") {
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }
    return base.appendingPathComponent(expanded).standardizedFileURL
}

func isDirectory(_ url: URL) -> Bool {
    var isDir = ObjCBool(false)
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
}

func pathExists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

func firstNonEmptyLine(_ text: String) -> String? {
    text.split(whereSeparator: \.isNewline)
        .map(String.init)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first(where: { !$0.isEmpty })
}

func escapeForShellSingleQuotes(_ value: String) -> String {
    let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
    return "'\(escaped)'"
}

func parseOwnerRepo(from remoteURL: String) -> (owner: String, repo: String)? {
    let pattern = #"github\.com[:/]([^/]+)/([^/.]+)(\.git)?$"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return nil
    }

    let range = NSRange(remoteURL.startIndex..<remoteURL.endIndex, in: remoteURL)
    guard let match = regex.firstMatch(in: remoteURL, range: range), match.numberOfRanges >= 3,
          let ownerRange = Range(match.range(at: 1), in: remoteURL),
          let repoRange = Range(match.range(at: 2), in: remoteURL)
    else {
        return nil
    }

    return (String(remoteURL[ownerRange]), String(remoteURL[repoRange]))
}

func findGenerateAppcast(env: [String: String]) throws -> String {
    if let explicitPath = env["SPARKLE_GENERATE_APPCAST"], !explicitPath.isEmpty {
        let expanded = expandedPath(explicitPath)
        if FileManager.default.isExecutableFile(atPath: expanded) {
            return expanded
        }
    }

    let derivedData = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Developer/Xcode/DerivedData")

    guard pathExists(derivedData) else {
        throw CommandError(message: "Could not find Sparkle generate_appcast. Set SPARKLE_GENERATE_APPCAST.")
    }

    let findResult = try runProcess(
        "/usr/bin/find",
        [
            derivedData.path,
            "-type", "f",
            "(",
            "-path", "*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast",
            "-o",
            "-path", "*/SourcePackages/checkouts/Sparkle/generate_appcast",
            ")"
        ],
        allowFailure: true
    )

    if let first = firstNonEmptyLine(findResult.stdout), FileManager.default.isExecutableFile(atPath: first) {
        return first
    }

    throw CommandError(message: "Could not find Sparkle generate_appcast. Set SPARKLE_GENERATE_APPCAST.")
}

func makeArchiveIfNeeded(
    inputURL: URL,
    appName: String,
    version: String,
    channel: ReleaseChannel,
    releaseArtifactsDir: URL
) throws -> URL {
    try FileManager.default.createDirectory(at: releaseArtifactsDir, withIntermediateDirectories: true)
    let channelSuffix = channel == .beta ? "-beta" : ""

    if isDirectory(inputURL), inputURL.pathExtension.lowercased() == "app" {
        let outputURL = releaseArtifactsDir.appendingPathComponent("\(appName)-\(version)\(channelSuffix).zip")
        if pathExists(outputURL) {
            try FileManager.default.removeItem(at: outputURL)
        }

        print("Packaging exported app into \(outputURL.lastPathComponent)...")
        _ = try runProcess(
            "/usr/bin/ditto",
            ["-c", "-k", "--sequesterRsrc", "--keepParent", inputURL.path, outputURL.path],
            captureOutput: false
        )
        return outputURL
    }

    if pathExists(inputURL), inputURL.pathExtension.lowercased() == "zip" {
        return inputURL
    }

    throw CommandError(message: "Input must be a signed .app bundle or a .zip archive: \(inputURL.path)")
}

func validateBundleVersionInArchive(_ archiveURL: URL) throws {
    let command = "unzip -p \(escapeForShellSingleQuotes(archiveURL.path)) '*/Contents/Info.plist' | plutil -extract CFBundleVersion raw -o - -"
    let versionResult = try runProcess(
        "/bin/bash",
        ["-lc", command],
        allowFailure: true
    )

    let bundleVersion = versionResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    if versionResult.status != 0 || bundleVersion.isEmpty {
        throw CommandError(message: "Archive is missing CFBundleVersion. Sparkle requires a numeric build version.")
    }

    let numericPattern = "^[0-9]+([.][0-9]+)*$"
    let regex = try NSRegularExpression(pattern: numericPattern)
    let range = NSRange(bundleVersion.startIndex..<bundleVersion.endIndex, in: bundleVersion)
    let matches = regex.firstMatch(in: bundleVersion, range: range) != nil
    if !matches {
        throw CommandError(message: "CFBundleVersion must be numeric for Sparkle updates. Found: \(bundleVersion)")
    }
}

func copyReplacingIfNeeded(from source: URL, to destination: URL) throws {
    if source.standardizedFileURL == destination.standardizedFileURL {
        return
    }
    if pathExists(destination) {
        try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.copyItem(at: source, to: destination)
}

func replaceRegex(_ pattern: String, in input: String, with replacement: String) throws -> String {
    let regex = try NSRegularExpression(pattern: pattern)
    let range = NSRange(input.startIndex..<input.endIndex, in: input)
    return regex.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: replacement)
}

func upsertReleaseNotesLink(in appcast: String, releaseNotesURL: String) throws -> String {
    let linkPattern = "sparkle:releaseNotesLink=\"[^\"]*\""
    let regex = try NSRegularExpression(pattern: linkPattern)
    let range = NSRange(appcast.startIndex..<appcast.endIndex, in: appcast)

    if regex.firstMatch(in: appcast, options: [], range: range) != nil {
        return regex.stringByReplacingMatches(
            in: appcast,
            options: [],
            range: range,
            withTemplate: "sparkle:releaseNotesLink=\"\(releaseNotesURL)\""
        )
    }

    if let itemRange = appcast.range(of: "<item>") {
        var output = appcast
        output.replaceSubrange(itemRange, with: "<item sparkle:releaseNotesLink=\"\(releaseNotesURL)\">")
        return output
    }

    return appcast
}

func ensureEdSignaturePresent(in appcast: String) throws {
    let signaturePattern = #"sparkle:edSignature="[^"]+""#
    let regex = try NSRegularExpression(pattern: signaturePattern)
    let range = NSRange(appcast.startIndex..<appcast.endIndex, in: appcast)
    guard regex.firstMatch(in: appcast, options: [], range: range) != nil else {
        throw CommandError(message: "Generated appcast is missing sparkle:edSignature. Ensure SPARKLE_PRIVATE_KEY_PATH points to a valid Sparkle EdDSA private key.")
    }
}

func publishReleaseIfPossible(
    ghPath: String?,
    owner: String,
    repo: String,
    tag: String,
    releaseTitle: String,
    isPrerelease: Bool,
    archiveURL: URL,
    releaseNotesPath: URL?
) throws {
    guard let ghPath else {
        print("Skipping GitHub Release publish: gh is not installed.")
        return
    }

    let auth = try runProcess(ghPath, ["auth", "status"], allowFailure: true)
    if auth.status != 0 {
        print("Skipping GitHub Release publish: gh is not authenticated.")
        return
    }

    let repoRef = "\(owner)/\(repo)"
    let releaseView = try runProcess(
        ghPath,
        ["release", "view", tag, "--repo", repoRef],
        allowFailure: true
    )

    if releaseView.status != 0 {
        print("Creating GitHub Release \(tag)...")
        var createArgs = ["release", "create", tag, "--repo", repoRef, "--title", releaseTitle]
        if let releaseNotesPath {
            createArgs += ["--notes-file", releaseNotesPath.path]
        } else {
            createArgs += ["--notes", releaseTitle]
        }
        if isPrerelease {
            createArgs.append("--prerelease")
        }
        _ = try runProcess(ghPath, createArgs, captureOutput: false)
    } else {
        print("Uploading asset to existing GitHub Release \(tag)...")
    }

    print("Uploading \(archiveURL.lastPathComponent) to GitHub Release \(tag)...")
    _ = try runProcess(
        ghPath,
        [
            "release", "upload", tag, archiveURL.path,
            "--repo", repoRef,
            "--clobber"
        ],
        captureOutput: false
    )
}

func resolveRepoRoot() throws -> URL {
    let env = ProcessInfo.processInfo.environment
    if let override = env["SWIFTMINER_ROOT"], !override.isEmpty {
        return URL(fileURLWithPath: expandedPath(override)).standardizedFileURL
    }

    let result = try runProcess("/usr/bin/git", ["rev-parse", "--show-toplevel"])
    let rootPath = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rootPath.isEmpty else {
        throw CommandError(message: "Could not determine repository root.")
    }
    return URL(fileURLWithPath: rootPath).standardizedFileURL
}

func main() throws {
    let parsed = try parseArguments(Array(CommandLine.arguments.dropFirst()))
    let version = parsed.version
    let channel = parsed.channel
    let channelSuffix = channel == .beta ? "-beta" : ""
    let appName = "SwiftMiner"
    let currentDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let inputURL = absoluteURL(parsed.artifactPath, relativeTo: currentDir)
    let releaseNotesInputURL: URL? = parsed.releaseNotesPath.map { absoluteURL($0, relativeTo: currentDir) }

    guard pathExists(inputURL) else {
        throw CommandError(message: "Input not found: \(inputURL.path)")
    }

    if let releaseNotesInputURL, !pathExists(releaseNotesInputURL) {
        throw CommandError(message: "Release notes not found: \(releaseNotesInputURL.path)")
    }

    let rootDir = try resolveRepoRoot()
    let docsDir = rootDir.appendingPathComponent("docs", isDirectory: true)
    let appcastDir = channel == .beta ? docsDir.appendingPathComponent("beta", isDirectory: true) : docsDir
    let appcastPath = appcastDir.appendingPathComponent("appcast.xml")
    let releaseArtifactsDir = rootDir.appendingPathComponent("release-artifacts", isDirectory: true)

    let env = ProcessInfo.processInfo.environment
    let generateAppcastPath = try findGenerateAppcast(env: env)

    let remoteResult = try runProcess("/usr/bin/git", ["-C", rootDir.path, "remote", "get-url", "origin"])
    let remoteURL = remoteResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

    guard let (owner, repo) = parseOwnerRepo(from: remoteURL) else {
        throw CommandError(message: "Could not parse GitHub owner/repo from origin: \(remoteURL)")
    }

    let tag = "v\(version)\(channelSuffix)"
    let releaseTitle = channel == .beta ? "\(appName) \(version) Beta" : "\(appName) \(version)"
    let pagesBaseURL = "https://\(owner).github.io/\(repo)"
    let channelPagesBaseURL = channel == .beta ? "\(pagesBaseURL)/beta" : pagesBaseURL

    let archiveURL = try makeArchiveIfNeeded(
        inputURL: inputURL,
        appName: appName,
        version: version,
        channel: channel,
        releaseArtifactsDir: releaseArtifactsDir
    )
    try validateBundleVersionInArchive(archiveURL)

    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("sparkle-publish-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let tempArchiveURL = tempDir.appendingPathComponent(archiveURL.lastPathComponent)
    try copyReplacingIfNeeded(from: archiveURL, to: tempArchiveURL)

    var releaseNotesPublishedURL: String?
    var releaseNotesCopiedURL: URL?
    if let releaseNotesInputURL {
        let releaseNotesDir = channel == .beta
            ? docsDir.appendingPathComponent("beta/release-notes", isDirectory: true)
            : docsDir.appendingPathComponent("release-notes", isDirectory: true)
        try FileManager.default.createDirectory(at: releaseNotesDir, withIntermediateDirectories: true)
        let targetName = "\(version).html"
        let releaseNotesOutputURL = releaseNotesDir.appendingPathComponent(targetName)
        try copyReplacingIfNeeded(from: releaseNotesInputURL, to: releaseNotesOutputURL)
        releaseNotesCopiedURL = releaseNotesInputURL
        releaseNotesPublishedURL = "\(channelPagesBaseURL)/release-notes/\(targetName)"
    }

    var generateArgs = [tempDir.path]
    if let privateKeyPath = env["SPARKLE_PRIVATE_KEY_PATH"], !privateKeyPath.isEmpty {
        let help = try runProcess(generateAppcastPath, ["-h"], allowFailure: true)
        if help.stdout.contains("--ed-key-file") || help.stderr.contains("--ed-key-file") {
            generateArgs += ["--ed-key-file", expandedPath(privateKeyPath)]
        }
    }

    _ = try runProcess(generateAppcastPath, generateArgs, captureOutput: false)

    let generatedFiles = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
    guard let generatedAppcast = generatedFiles.first(where: { $0.pathExtension.lowercased() == "xml" }) else {
        throw CommandError(message: "generate_appcast did not produce an XML file in \(tempDir.path)")
    }

    try FileManager.default.createDirectory(at: appcastDir, withIntermediateDirectories: true)
    try copyReplacingIfNeeded(from: generatedAppcast, to: appcastPath)

    var appcastContents = try String(contentsOf: appcastPath, encoding: .utf8)
    let escapedAssetName = NSRegularExpression.escapedPattern(for: archiveURL.lastPathComponent)
    appcastContents = try replaceRegex(
        "url=\\\"[^\\\"]*\(escapedAssetName)\\\"",
        in: appcastContents,
        with: "url=\\\"https://github.com/\(owner)/\(repo)/releases/download/\(tag)/\(archiveURL.lastPathComponent)\\\""
    )

    if let releaseNotesPublishedURL {
        appcastContents = try upsertReleaseNotesLink(in: appcastContents, releaseNotesURL: releaseNotesPublishedURL)
    }

    try ensureEdSignaturePresent(in: appcastContents)
    try appcastContents.write(to: appcastPath, atomically: true, encoding: .utf8)

    try publishReleaseIfPossible(
        ghPath: findExecutable(named: "gh"),
        owner: owner,
        repo: repo,
        tag: tag,
        releaseTitle: releaseTitle,
        isPrerelease: channel == .beta,
        archiveURL: archiveURL,
        releaseNotesPath: releaseNotesCopiedURL
    )

    let downloadURL = "https://github.com/\(owner)/\(repo)/releases/download/\(tag)/\(archiveURL.lastPathComponent)"
    print("Updated appcast: \(appcastPath.path)")
    print("Archive: \(archiveURL.path)")
    print("Release channel: \(channel.rawValue)")
    print("Release asset URL: \(downloadURL)")
    if let releaseNotesPublishedURL {
        print("Release notes URL: \(releaseNotesPublishedURL)")
    }
    print()
    print("Next:")
    print("1. Verify GitHub Release \(tag) exists and contains \(archiveURL.lastPathComponent)")
    let notesPath = channel == .beta ? "docs/beta/release-notes/*.html" : "docs/release-notes/*.html"
    let appcastRelativePath = channel == .beta ? "docs/beta/appcast.xml" : "docs/appcast.xml"
    print("2. Commit \(appcastRelativePath) and any \(notesPath) changes")
    print("3. Push main so GitHub Pages publishes the updated appcast")
}

do {
    try main()
} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
