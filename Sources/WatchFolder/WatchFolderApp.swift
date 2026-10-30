import SwiftUI
import AppKit
import UserNotifications
import WatchFolderCore

struct LogEntry: Identifiable {
    let id = UUID()
    let text: String
}

@MainActor
final class WatchViewModel: ObservableObject {
    @Published var folder: URL?
    @Published var entries: [LogEntry] = []
    @Published var isWatching = false
    @Published var isStarting = false
    @Published var errorMessage: String?

    private var monitor: FolderMonitor?
    private var startTask: Task<Void, Never>?
    private var startGeneration = 0
    private let defaultsKey = "lastFolderPath"

    init() {
        if let path = UserDefaults.standard.string(forKey: defaultsKey) {
            folder = URL(fileURLWithPath: path)
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Watch"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        stop()
        folder = url
        UserDefaults.standard.set(url.path, forKey: defaultsKey)
    }

    func start() {
        guard let folder, !isWatching, !isStarting else { return }
        errorMessage = nil
        isStarting = true
        startGeneration += 1
        let generation = startGeneration
        startTask = Task {
            defer {
                if generation == startGeneration {
                    isStarting = false
                    startTask = nil
                }
            }

            let center = UNUserNotificationCenter.current()
            var notificationsEnabled = false
            var notificationIssue: String?
            do {
                let settings = await center.notificationSettings()
                switch settings.authorizationStatus {
                case .authorized, .provisional:
                    notificationsEnabled = true
                case .notDetermined:
                    notificationsEnabled = try await center.requestAuthorization(options: [.alert])
                    if !notificationsEnabled {
                        notificationIssue = Self.notificationsDisabledMessage
                    }
                default:
                    notificationIssue = Self.notificationsDisabledMessage
                }
            } catch {
                notificationIssue = "Could not enable notifications: \(error.localizedDescription)"
            }

            guard !Task.isCancelled, generation == startGeneration else { return }
            startMonitoring(folder, notificationsEnabled: notificationsEnabled,
                            notificationIssue: notificationIssue)
        }
    }

    private static let notificationsDisabledMessage =
        "Watching, but notifications are disabled. Enable alerts for WatchFolder in System Settings > Notifications."

    private func startMonitoring(_ folder: URL, notificationsEnabled: Bool,
                                notificationIssue: String?) {
        errorMessage = notificationIssue
        let m = FolderMonitor(
            folder: folder,
            onEvent: { [weak self] event, line in
                self?.entries.append(LogEntry(text: line.trimmingCharacters(in: .newlines)))
                guard notificationsEnabled else { return }
                self?.postNotification(for: event)
            },
            onError: { [weak self] error in
                self?.errorMessage = error.localizedDescription
                self?.isWatching = false
                self?.monitor = nil
            })
        do {
            try m.start()
            monitor = m
            isWatching = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func postNotification(for event: FileEvent) {
        let content = UNMutableNotificationContent()
        content.title = "WatchFolder"
        content.body = event.message
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                self?.errorMessage = "Could not show notification: \(error.localizedDescription)"
            }
        }
    }

    func stop() {
        startGeneration += 1
        startTask?.cancel()
        startTask = nil
        isStarting = false
        monitor?.stop()
        monitor = nil
        isWatching = false
    }

    func revealLog() {
        guard let folder else { return }
        let log = folder.appendingPathComponent(logFileName)
        if FileManager.default.fileExists(atPath: log.path) {
            NSWorkspace.shared.activateFileViewerSelecting([log])
        } else {
            NSWorkspace.shared.open(folder)
        }
    }
}

struct ContentView: View {
    @StateObject private var model = WatchViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Choose Folder…") { model.chooseFolder() }
                Text(model.folder?.path ?? "No folder selected")
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            HStack {
                if model.isWatching {
                    Button("Stop") { model.stop() }
                } else {
                    Button(model.isStarting ? "Starting…" : "Start Watching") { model.start() }
                        .disabled(model.folder == nil || model.isStarting)
                        .keyboardShortcut(.defaultAction)
                }
                Button("Reveal Log") { model.revealLog() }.disabled(model.folder == nil)
                Button("Clear") { model.entries.removeAll() }.disabled(model.entries.isEmpty)
                Spacer()
                Label(model.isWatching ? "Watching" : (model.isStarting ? "Starting" : "Idle"),
                      systemImage: model.isWatching ? "eye.fill" : "eye.slash")
                    .foregroundStyle(model.isWatching ? .green : .secondary)
            }
            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            ScrollViewReader { proxy in
                List(model.entries) { entry in
                    Text(entry.text).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        .id(entry.id)
                }
                .onChange(of: model.entries.count) { _ in
                    if let last = model.entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .padding()
        .frame(minWidth: 560, minHeight: 360)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct WatchFolderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("WatchFolder") { ContentView() }
    }
}
