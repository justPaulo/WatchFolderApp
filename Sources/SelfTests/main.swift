import Foundation
import WatchFolderCore

// XCTest replacement: run with `swift run SelfTests`. Exit code 0 = all passed.

var failures = 0
var checks = 0

func check(_ condition: @autoclosure () -> Bool, _ name: String, line: Int = #line) {
    checks += 1
    if condition() {
        print("  ok   \(name)")
    } else {
        failures += 1
        print("  FAIL \(name) (line \(line))")
    }
}

func fid(_ d: Int64, _ i: Int64) -> FileIdentity { FileIdentity(device: d, inode: i) }
func st(_ d: Int64, _ i: Int64, size: Int64 = 1, mtime: Double = 1) -> FileState {
    FileState(identity: fid(d, i), size: size, modified: mtime)
}

print("FileTracker")
check(FileTracker.changes(from: ["a": st(1, 1)], to: ["a": st(1, 1)]).isEmpty, "no changes")
check(FileTracker.changes(from: [:], to: ["a": st(1, 1)]) == [.added("a")], "added")
check(FileTracker.changes(from: ["a": st(1, 1)], to: [:]) == [.removed("a")], "removed")
check(FileTracker.changes(from: ["a": st(1, 1)], to: ["b": st(1, 1)]) == [.renamed(from: "a", to: "b")], "renamed")
check(FileTracker.changes(from: ["a": st(1, 1)], to: ["a": st(1, 1, size: 9)]) == [.modified("a")], "modified (size)")
check(FileTracker.changes(from: ["a": st(1, 1)], to: ["a": st(1, 1, mtime: 2)]) == [.modified("a")], "modified (mtime)")
check(FileTracker.changes(from: ["a": st(1, 1)], to: ["a": st(1, 2)]) == [.modified("a")], "replaced in place (new inode)")
let swap = FileTracker.changes(from: ["a": st(1, 1), "b": st(1, 2)], to: ["c": st(1, 1), "d": st(1, 2)])
check(swap == [.renamed(from: "a", to: "c"), .renamed(from: "b", to: "d")], "two simultaneous renames")
let hardlinks = FileTracker.changes(from: ["a": st(1, 1), "b": st(1, 1)], to: ["c": st(1, 1), "d": st(1, 1)])
check(hardlinks.count == 2 && !hardlinks.contains { if case .added = $0 { return true } else { return false } }, "hard-link renames pair up")
let populatedFolder = ["folder": st(1, 1), "folder/nested.txt": st(1, 2)]
check(FileTracker.changes(from: populatedFolder, to: [:])
      == [.removed("folder/nested.txt"), .removed("folder")],
      "nested removals are reported before their parent directory")
check(FileTracker.changes(from: [:], to: populatedFolder)
      == [.added("folder"), .added("folder/nested.txt")],
      "parent directories are reported before nested additions")

print("FolderScanner / Monitor")
let fm = FileManager.default
let tmp = fm.temporaryDirectory.appendingPathComponent("watchfolder-selftest-\(UUID().uuidString)")
try! fm.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: tmp) }

fm.createFile(atPath: tmp.appendingPathComponent("one.txt").path, contents: Data("x".utf8))
try! fm.createDirectory(at: tmp.appendingPathComponent("plain-dir"), withIntermediateDirectories: false)
try! fm.createDirectory(at: tmp.appendingPathComponent("Thing.app"), withIntermediateDirectories: false)
fm.createFile(atPath: tmp.appendingPathComponent("plain-dir/nested.txt").path, contents: Data("x".utf8))
fm.createFile(atPath: tmp.appendingPathComponent("Thing.app/inside").path, contents: Data("x".utf8))
fm.createFile(atPath: tmp.appendingPathComponent(logFileName).path, contents: nil)
fm.createFile(atPath: tmp.appendingPathComponent(".DS_Store").path, contents: Data("x".utf8))
fm.createFile(atPath: tmp.appendingPathComponent("._one.txt").path, contents: Data("x".utf8))

let snap = try! FolderScanner.snapshot(of: tmp)
check(Set(snap.keys) == ["one.txt", "plain-dir", "plain-dir/nested.txt", "Thing.app"],
      "scanner: recursively includes ordinary directories and keeps packages atomic")

print("FolderLock")
do {
    let first = try FolderLock(folder: tmp)
    var blocked = false
    do { _ = try FolderLock(folder: tmp) } catch WatcherError.alreadyWatching { blocked = true } catch {}
    check(blocked, "second lock refused while first is held")
    first.release()
    var reacquired = false
    do { let again = try FolderLock(folder: tmp); again.release(); reacquired = true } catch {}
    check(reacquired, "lock can be reacquired after release")
} catch {
    check(false, "lock acquisition failed: \(error)")
}

print("EventLog")
let log = EventLog(folder: tmp)
let line = try! log.append(.added("x.txt"), at: Date(timeIntervalSince1970: 0))
check(line == "1970-01-01T00:00:00.000Z Added: x.txt\n", "log line format")
_ = try! log.append(.renamed(from: "a", to: "b"))
let contents = try! String(contentsOf: log.url, encoding: .utf8)
check(contents.split(separator: "\n").count == 2, "log appends lines")

print("FolderMonitor (live)")
let monitored = fm.temporaryDirectory.appendingPathComponent("watchfolder-live-\(UUID().uuidString)")
try! fm.createDirectory(at: monitored, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: monitored) }

var seen: [FileEvent] = []
let monitor = FolderMonitor(folder: monitored, interval: 0.1,
                            onEvent: { e, _ in seen.append(e) }, onError: { _ in })
try! monitor.start()
let dsStore = monitored.appendingPathComponent(".DS_Store")
fm.createFile(atPath: dsStore.path, contents: Data("x".utf8))
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
try! Data("updated".utf8).write(to: dsStore)
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
let nestedFolder = monitored.appendingPathComponent("folder")
try! fm.createDirectory(at: nestedFolder, withIntermediateDirectories: false)
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
let nestedFile = nestedFolder.appendingPathComponent("nested.txt")
fm.createFile(atPath: nestedFile.path, contents: Data())
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
try! fm.removeItem(at: nestedFile)
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
try! fm.removeItem(at: nestedFolder)
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
fm.createFile(atPath: monitored.appendingPathComponent("a.txt").path, contents: Data())
RunLoop.main.run(until: Date().addingTimeInterval(0.6))
try! fm.moveItem(at: monitored.appendingPathComponent("a.txt"), to: monitored.appendingPathComponent("b.txt"))
RunLoop.main.run(until: Date().addingTimeInterval(0.6))
try! fm.removeItem(at: monitored.appendingPathComponent("b.txt"))
RunLoop.main.run(until: Date().addingTimeInterval(0.6))
monitor.stop()
check(seen == [
    .added("folder"),
    .added("folder/nested.txt"),
    .removed("folder/nested.txt"),
    .removed("folder"),
    .added("a.txt"),
    .renamed(from: "a.txt", to: "b.txt"),
    .removed("b.txt")
], "live directory creation, population and deletion; ignores .DS_Store")

print("\n\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE)
