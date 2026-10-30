import Foundation

public struct FileIdentity: Hashable {
    public let device: Int64
    public let inode: Int64
    public init(device: Int64, inode: Int64) {
        self.device = device
        self.inode = inode
    }
}

/// Identity plus size/mtime, so in-place edits and atomic-save replacements are noticed too.
public struct FileState: Equatable {
    public let identity: FileIdentity
    public let size: Int64
    public let modified: Double
    public init(identity: FileIdentity, size: Int64 = 0, modified: Double = 0) {
        self.identity = identity
        self.size = size
        self.modified = modified
    }
}

public enum FileEvent: Equatable {
    case added(String)
    case removed(String)
    case renamed(from: String, to: String)
    case modified(String)

    public var message: String {
        switch self {
        case .added(let p): return "Added: \(p)"
        case .removed(let p): return "Removed: \(p)"
        case .renamed(let a, let b): return "Renamed: \(a) -> \(b)"
        case .modified(let p): return "Modified: \(p)"
        }
    }
}

public enum FileTracker {
    public static func changes(from previous: [String: FileState],
                               to current: [String: FileState]) -> [FileEvent] {
        let removed = previous.keys.filter { current[$0] == nil }.sorted {
            let lhsDepth = $0.filter { $0 == "/" }.count
            let rhsDepth = $1.filter { $0 == "/" }.count
            return lhsDepth == rhsDepth ? $0 < $1 : lhsDepth > rhsDepth
        }
        let added = current.keys.filter { previous[$0] == nil }.sorted {
            let lhsDepth = $0.filter { $0 == "/" }.count
            let rhsDepth = $1.filter { $0 == "/" }.count
            return lhsDepth == rhsDepth ? $0 < $1 : lhsDepth < rhsDepth
        }

        var addedByIdentity: [FileIdentity: [String]] = [:]
        for path in added {
            addedByIdentity[current[path]!.identity, default: []].append(path)
        }

        var events: [FileEvent] = []
        var consumedOld = Set<String>()
        var consumedNew = Set<String>()

        for oldPath in removed {
            let id = previous[oldPath]!.identity
            guard var candidates = addedByIdentity[id], !candidates.isEmpty else { continue }
            let newPath = candidates.removeFirst()
            addedByIdentity[id] = candidates
            consumedOld.insert(oldPath)
            consumedNew.insert(newPath)
            events.append(.renamed(from: oldPath, to: newPath))
        }

        events += removed.filter { !consumedOld.contains($0) }.map(FileEvent.removed)
        events += added.filter { !consumedNew.contains($0) }.map(FileEvent.added)

        for path in previous.keys.sorted() {
            if let now = current[path], now != previous[path] {
                events.append(.modified(path))
            }
        }
        return events
    }
}
