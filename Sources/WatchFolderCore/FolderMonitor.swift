import Foundation
import Darwin

public enum WatcherError: LocalizedError {
    case notADirectory(String)
    case cannotCreateLog(String)
    case alreadyWatching(String)
    case posix(Int32)

    public var errorDescription: String? {
        switch self {
        case .notADirectory(let p): return "The path is not a directory: \(p)"
        case .cannotCreateLog(let p): return "Could not create the event log: \(p)"
        case .alreadyWatching(let p): return "Another watchfolder instance is already watching \(p)"
        case .posix(let code): return String(cString: strerror(code))
        }
    }
}

public let logFileName = "watchfolder.log"
public let lockFileName = ".watchfolder.lock"

/// Names the watcher never reports: its own files and macOS Finder metadata noise.
public func isIgnored(_ name: String) -> Bool {
    name == logFileName || name == lockFileName
        || name == ".DS_Store" || name.hasPrefix("._")
}

/// Snapshot of regular files and packages, plus ordinary directories recursively.
public enum FolderScanner {
    public static func snapshot(of folder: URL) throws -> [String: FileState] {
        let fm = FileManager.default
        var result: [String: FileState] = [:]
        try collect(from: folder, relativePath: "", isRoot: true, into: &result, fileManager: fm)
        return result
    }

    private static func collect(from folder: URL, relativePath: String, isRoot: Bool,
                               into result: inout [String: FileState],
                               fileManager fm: FileManager) throws {
        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [])
        } catch let error as CocoaError where !isRoot && error.code == .fileReadNoSuchFile {
            return
        }
        for url in urls {
            let name = url.lastPathComponent
            if name == ".DS_Store" || name.hasPrefix("._") || (isRoot && isIgnored(name)) { continue }

            let attrs: [FileAttributeKey: Any]
            do {
                attrs = try fm.attributesOfItem(atPath: url.path)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                continue // vanished between listing and stat
            }
            guard let type = attrs[.type] as? FileAttributeType else { continue }

            let isDirectory = type == .typeDirectory
            guard type == .typeRegular || isDirectory,
                  let dev = (attrs[.systemNumber] as? NSNumber)?.int64Value,
                  let ino = (attrs[.systemFileNumber] as? NSNumber)?.int64Value else { continue }

            let path = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
            let isPackage = isDirectory
                && (url.pathExtension.caseInsensitiveCompare("app") == .orderedSame
                    || ((try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false))
            let size = isDirectory ? 0 : (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = isDirectory ? 0 : (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            result[path] = FileState(identity: FileIdentity(device: dev, inode: ino),
                                     size: size, modified: mtime)

            if isDirectory && !isPackage {
                try collect(from: url, relativePath: path, isRoot: false,
                            into: &result, fileManager: fm)
            }
        }
    }
}

/// Exclusive advisory lock so two instances never watch the same folder.
/// Uses flock(2), which conflicts per open file description (works inside one process too).
public final class FolderLock {
    private var fd: Int32

    public init(folder: URL) throws {
        let path = folder.appendingPathComponent(lockFileName).path
        fd = Darwin.open(path, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        guard fd >= 0 else { throw WatcherError.posix(errno) }
        // Unqualified on purpose: `Darwin.flock` resolves to the struct, not the function.
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let err = errno
            Darwin.close(fd)
            fd = -1
            if err == EWOULDBLOCK || err == EAGAIN { throw WatcherError.alreadyWatching(folder.path) }
            throw WatcherError.posix(err)
        }
    }

    deinit { release() }

    public func release() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }
}

public struct EventLog {
    public let url: URL
    public init(folder: URL) { url = folder.appendingPathComponent(logFileName) }

    public func prepare() throws {
        if !FileManager.default.fileExists(atPath: url.path),
           !FileManager.default.createFile(atPath: url.path, contents: nil) {
            throw WatcherError.cannotCreateLog(url.path)
        }
    }

    /// Appends one line and returns the full line that was written.
    @discardableResult
    public func append(_ event: FileEvent, at date: Date = Date()) throws -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = "\(f.string(from: date)) \(event.message)\n"
        let bytes = Array(line.utf8)

        let fd = Darwin.open(url.path, O_WRONLY | O_APPEND | O_CREAT, mode_t(S_IRUSR | S_IWUSR))
        guard fd >= 0 else { throw WatcherError.posix(errno) }
        defer { Darwin.close(fd) }

        var written = 0
        while written < bytes.count {
            let n = bytes[written...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw WatcherError.posix(errno)
            }
            written += n
        }
        return line
    }
}

/// Polls a folder and reports changes. Callbacks arrive on the main queue.
public final class FolderMonitor: @unchecked Sendable {
    public let folder: URL
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "watchfolder.monitor")
    private var timer: DispatchSourceTimer?
    private var lock: FolderLock?
    private var previous: [String: FileState] = [:]
    private let log: EventLog
    private let onEvent: (FileEvent, String) -> Void
    private let onError: (Error) -> Void

    public init(folder: URL, interval: TimeInterval = 0.5,
                onEvent: @escaping (FileEvent, String) -> Void,
                onError: @escaping (Error) -> Void) {
        self.folder = folder.standardizedFileURL
        self.interval = interval
        self.log = EventLog(folder: self.folder)
        self.onEvent = onEvent
        self.onError = onError
    }

    public func start() throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            throw WatcherError.notADirectory(folder.path)
        }
        lock = try FolderLock(folder: folder)
        do {
            try log.prepare()
            previous = try FolderScanner.snapshot(of: folder)
        } catch {
            lock?.release(); lock = nil
            throw error
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    public func stop() {
        timer?.cancel(); timer = nil
        lock?.release(); lock = nil
    }

    private func tick() {
        do {
            let current = try FolderScanner.snapshot(of: folder)
            for event in FileTracker.changes(from: previous, to: current) {
                let line = try log.append(event)
                DispatchQueue.main.async { self.onEvent(event, line) }
            }
            previous = current
        } catch {
            stop()
            DispatchQueue.main.async { self.onError(error) }
        }
    }
}
