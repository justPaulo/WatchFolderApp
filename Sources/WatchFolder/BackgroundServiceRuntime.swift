import Foundation
import UserNotifications
import WatchFolderCore

final class BackgroundServiceRuntime {
    private var monitor: FolderMonitor?

    func start(folder: URL) throws {
        let center = UNUserNotificationCenter.current()
        let monitor = FolderMonitor(
            folder: folder,
            onEvent: { event, line in
                FileHandle.standardOutput.write(Data(line.utf8))
                let content = UNMutableNotificationContent()
                content.title = "WatchFolder"
                content.body = event.message
                let request = UNNotificationRequest(
                    identifier: UUID().uuidString,
                    content: content,
                    trigger: nil
                )
                center.add(request) { error in
                    guard let error else { return }
                    let details = error as NSError
                    fputs(
                        "Could not show notification [\(details.domain):\(details.code)]: "
                            + "\(details.localizedDescription)\n",
                        stderr
                    )
                }
            },
            onError: { error in
                fputs("WatchFolder background service stopped: \(error.localizedDescription)\n",
                      stderr)
                exit(EXIT_FAILURE)
            }
        )
        try monitor.start()
        self.monitor = monitor
    }
}
