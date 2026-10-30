import Darwin
import Foundation
import UserNotifications
import WatchFolderCore

@main
enum WatchFolderService {
    static func main() {
        guard CommandLine.arguments.count == 2 else {
            fputs("WatchFolderService expects the folder path as its only argument.\n", stderr)
            exit(EXIT_FAILURE)
        }

        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let monitor = FolderMonitor(
            folder: folder,
            onEvent: { event, line in
                print(line, terminator: "")
                let content = UNMutableNotificationContent()
                content.title = "WatchFolder"
                content.body = event.message
                let request = UNNotificationRequest(
                    identifier: UUID().uuidString,
                    content: content,
                    trigger: nil
                )
                UNUserNotificationCenter.current().add(request) { error in
                    if let error {
                        fputs("Could not show notification: \(error.localizedDescription)\n", stderr)
                    }
                }
            },
            onError: { error in
                fputs("WatchFolder background service stopped: \(error.localizedDescription)\n", stderr)
                exit(EXIT_FAILURE)
            }
        )

        do {
            try monitor.start()
        } catch {
            fputs("Could not start WatchFolder background service: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }

        RunLoop.main.run()
    }
}
