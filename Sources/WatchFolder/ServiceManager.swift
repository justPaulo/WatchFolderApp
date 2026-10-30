import Darwin
import Foundation

enum ServiceManagerError: LocalizedError {
    case appBundleRequired
    case serviceExecutableMissing
    case folderUnavailable(String)
    case alreadyInstalled
    case staleInstallation(String)
    case notInstalled
    case launchctlFailed(String, Int32, String)
    case rollbackFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .appBundleRequired:
            return "Install the background service from the packaged WatchFolder.app."
        case .serviceExecutableMissing:
            return "The WatchFolder background service is missing from this app bundle. Rebuild the app and try again."
        case .folderUnavailable(let path):
            return "The selected folder is no longer available: \(path)"
        case .alreadyInstalled:
            return "The WatchFolder background service is already installed."
        case .staleInstallation(let path):
            return "An incomplete WatchFolder installation already exists at \(path). Uninstall it or remove it before installing again."
        case .notInstalled:
            return "The WatchFolder background service is not installed."
        case .launchctlFailed(let command, let status, let output):
            return "launchctl \(command) failed with exit status \(status): \(output)"
        case .rollbackFailed(let original, let cleanup):
            return "\(original) Installation cleanup also failed: \(cleanup)"
        }
    }
}

enum ServiceManager {
    static let label = "com.github.justpaulo.watchfolderapp.monitor"

    private static let fileManager = FileManager.default

    private static var supportDirectory: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WatchFolder", isDirectory: true)
    }

    private static var installedAppURL: URL {
        supportDirectory.appendingPathComponent("WatchFolder.app", isDirectory: true)
    }

    private static var agentURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    static var isInstalled: Bool {
        fileManager.fileExists(atPath: agentURL.path)
    }

    static func install(folder: URL, from sourceAppURL: URL) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ServiceManagerError.folderUnavailable(folder.path)
        }
        guard sourceAppURL.pathExtension == "app" else {
            throw ServiceManagerError.appBundleRequired
        }
        guard !isInstalled else {
            throw ServiceManagerError.alreadyInstalled
        }
        guard !fileManager.fileExists(atPath: installedAppURL.path) else {
            throw ServiceManagerError.staleInstallation(installedAppURL.path)
        }

        let sourceExecutable = sourceAppURL
            .appendingPathComponent("Contents/MacOS/WatchFolder")
        guard fileManager.isExecutableFile(atPath: sourceExecutable.path) else {
            throw ServiceManagerError.serviceExecutableMissing
        }

        try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: agentURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)

        var appCopyAttempted = false
        var plistWritten = false
        var bootstrapped = false
        do {
            appCopyAttempted = true
            try fileManager.copyItem(at: sourceAppURL, to: installedAppURL)

            let serviceExecutable = installedAppURL
                .appendingPathComponent("Contents/MacOS/WatchFolder")
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [
                    serviceExecutable.path,
                    "--background-service",
                    folder.standardizedFileURL.path
                ],
                "RunAtLoad": false,
                "KeepAlive": false,
                "StandardOutPath": supportDirectory.appendingPathComponent("service.log").path,
                "StandardErrorPath": supportDirectory.appendingPathComponent("service.log").path
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                          format: .xml, options: 0)
            try data.write(to: agentURL, options: .atomic)
            plistWritten = true

            try runLaunchctl(["bootstrap", launchdDomain, agentURL.path])
            bootstrapped = true
            try runLaunchctl(["kickstart", "\(launchdDomain)/\(label)"])
        } catch {
            let originalMessage = error.localizedDescription
            var cleanupErrors: [String] = []
            if bootstrapped {
                do {
                    try runLaunchctl(["bootout", launchdDomain, agentURL.path])
                } catch {
                    cleanupErrors.append(error.localizedDescription)
                }
            }
            if plistWritten {
                do {
                    try fileManager.removeItem(at: agentURL)
                } catch {
                    cleanupErrors.append(error.localizedDescription)
                }
            }
            if appCopyAttempted && fileManager.fileExists(atPath: installedAppURL.path) {
                do {
                    try fileManager.removeItem(at: installedAppURL)
                } catch {
                    cleanupErrors.append(error.localizedDescription)
                }
            }
            if !cleanupErrors.isEmpty {
                throw ServiceManagerError.rollbackFailed(originalMessage,
                                                         cleanupErrors.joined(separator: " "))
            }
            throw error
        }
    }

    static func uninstall() throws {
        guard isInstalled else { throw ServiceManagerError.notInstalled }
        try runLaunchctl(["bootout", launchdDomain, agentURL.path])
        try fileManager.removeItem(at: agentURL)
        if fileManager.fileExists(atPath: installedAppURL.path) {
            try fileManager.removeItem(at: installedAppURL)
        }
    }

    private static var launchdDomain: String {
        "gui/\(getuid())"
    }

    private static func runLaunchctl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let command = arguments.first ?? ""
            throw ServiceManagerError.launchctlFailed(
                command,
                process.terminationStatus,
                message.isEmpty ? "No additional details." : message
            )
        }
    }
}
