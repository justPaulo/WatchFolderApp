import Darwin
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
    @Published var isCheckingService = true
    @Published var isServiceInstalled = false
    @Published var isServiceActionInProgress = false
    @Published var showServiceInstalledAlert = false
    @Published var serviceInstalledAlertMessage = ""

    private var monitor: FolderMonitor?
    private var startTask: Task<Void, Never>?
    private var startGeneration = 0
    private var pendingServiceError: String?
    private let defaultsKey = "lastFolderPath"

    init() {
        if let path = UserDefaults.standard.string(forKey: defaultsKey) {
            folder = URL(fileURLWithPath: path)
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isServiceInstalled = ServiceManager.isInstalled
            self.isCheckingService = false
            if self.isServiceInstalled {
                self.refreshServiceLog()
            }
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

    func installService() {
        guard let folder, !isCheckingService, !isServiceInstalled,
              !isServiceActionInProgress, !isStarting else { return }
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            errorMessage = "Install the background service from the packaged WatchFolder.app."
            return
        }
        errorMessage = nil
        isServiceActionInProgress = true
        Task {
            defer { isServiceActionInProgress = false }
            let notificationIssue = await requestServiceNotifications()
            let wasWatching = isWatching
            if wasWatching { stop() }
            do {
                let appURL = Bundle.main.bundleURL
                try await Task.detached(priority: .userInitiated) {
                    try ServiceManager.install(folder: folder, from: appURL)
                }.value
                isServiceInstalled = true
                let notificationNote = notificationIssue.map { "\n\n\($0)" } ?? ""
                serviceInstalledAlertMessage =
                    "Background monitoring of \(folder.path) has started. This window will close because the service now runs independently. Use Uninstall to stop and remove it. The service will not restart automatically after logout or restart.\(notificationNote)"
                showServiceInstalledAlert = true
            } catch {
                let message = "Could not install background service: \(error.localizedDescription)"
                if wasWatching {
                    pendingServiceError = message
                    start()
                } else {
                    errorMessage = message
                }
            }
        }
    }

    func uninstallService() {
        guard !isCheckingService, isServiceInstalled, !isServiceActionInProgress else { return }
        errorMessage = nil
        isServiceActionInProgress = true
        Task {
            defer { isServiceActionInProgress = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try ServiceManager.uninstall()
                }.value
                isServiceInstalled = false
            } catch {
                errorMessage = "Could not uninstall background service: \(error.localizedDescription)"
            }
        }
    }

    func refreshServiceLog() {
        guard isServiceInstalled, let folder else { return }
        let logURL = folder.appendingPathComponent(logFileName)
        do {
            let contents = try String(contentsOf: logURL, encoding: .utf8)
            let lines = contents.components(separatedBy: .newlines)
                .filter { !$0.isEmpty }
                .suffix(500)
            entries = lines.map { LogEntry(text: $0) }
        } catch {
            errorMessage = "Could not read the background service log: \(error.localizedDescription)"
        }
    }

    private func requestServiceNotifications() async -> String? {
        let center = UNUserNotificationCenter.current()
        do {
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                return nil
            case .notDetermined:
                let enabled = try await center.requestAuthorization(options: [.alert])
                return enabled ? nil : Self.notificationsDisabledMessage
            default:
                return Self.notificationsDisabledMessage
            }
        } catch {
            return "Could not enable notifications: \(error.localizedDescription)"
        }
    }

    private func startMonitoring(_ folder: URL, notificationsEnabled: Bool,
                                notificationIssue: String?) {
        let issues = [pendingServiceError, notificationIssue].compactMap { $0 }
        errorMessage = issues.isEmpty ? nil : issues.joined(separator: "\n")
        pendingServiceError = nil
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

    private var appIcon: NSImage? {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else {
            return nil
        }
        return NSImage(contentsOf: iconURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Choose Folder…") { model.chooseFolder() }
                    .disabled(model.isServiceInstalled || model.isServiceActionInProgress)
                Text(model.folder?.path ?? "No folder selected")
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer()
                if let appIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 40, height: 40)
                        .accessibilityLabel("WatchFolder app icon")
                }
            }
            HStack {
                if model.isServiceInstalled {
                    Text("Background service installed")
                        .foregroundStyle(.secondary)
                } else if model.isWatching {
                    Button("Stop") { model.stop() }
                        .disabled(model.isServiceActionInProgress)
                } else {
                    Button(model.isStarting ? "Starting…" : "Start Watching") { model.start() }
                        .disabled(model.folder == nil || model.isStarting || model.isServiceActionInProgress)
                        .keyboardShortcut(.defaultAction)
                }
                Button("Reveal Log") { model.revealLog() }.disabled(model.folder == nil)
                Button("Clear") { model.entries.removeAll() }.disabled(model.entries.isEmpty)
                Button(model.isServiceActionInProgress && !model.isServiceInstalled
                       ? "Installing…" : "Install") {
                    model.installService()
                }
                .disabled(model.isCheckingService || model.isServiceInstalled
                          || model.isServiceActionInProgress || model.isStarting
                          || model.folder == nil)
                Button(model.isServiceActionInProgress && model.isServiceInstalled
                       ? "Uninstalling…" : "Uninstall") {
                    model.uninstallService()
                }
                .disabled(model.isCheckingService || !model.isServiceInstalled
                          || model.isServiceActionInProgress)
                if model.isCheckingService {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if model.isCheckingService {
                    Text("Checking service…").foregroundStyle(.secondary)
                } else if model.isServiceInstalled {
                    Text("Background service installed").foregroundStyle(.secondary)
                } else {
                    Label(model.isWatching ? "Watching" : (model.isStarting ? "Starting" : "Idle"),
                          systemImage: model.isWatching ? "eye.fill" : "eye.slash")
                        .foregroundStyle(model.isWatching ? .green : .secondary)
                }
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
        .alert("Background Service Installed", isPresented: $model.showServiceInstalledAlert) {
            Button("Close WatchFolder", role: .cancel) { NSApp.terminate(nil) }
        } message: {
            Text(model.serviceInstalledAlertMessage)
        }
        .task(id: model.isServiceInstalled) {
            guard model.isServiceInstalled else { return }
            model.refreshServiceLog()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
                model.refreshServiceLog()
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var backgroundService: BackgroundServiceRuntime?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        } else {
            NSLog("WatchFolder: could not load AppIcon.icns from the app bundle.")
        }
        UNUserNotificationCenter.current().delegate = self
        if let folder = WatchFolderApp.backgroundServiceFolder {
            NSApplication.shared.setActivationPolicy(.accessory)
            DispatchQueue.main.async {
                NSApplication.shared.hide(nil)
            }
            let service = BackgroundServiceRuntime()
            do {
                try service.start(folder: folder)
                backgroundService = service
            } catch {
                fputs("Could not start WatchFolder background service: \(error.localizedDescription)\n",
                      stderr)
                exit(EXIT_FAILURE)
            }
        }
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

    static var backgroundServiceFolder: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--background-service"),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    var body: some Scene {
        WindowGroup("WatchFolder") {
            if Self.backgroundServiceFolder != nil {
                EmptyView()
            } else {
                ContentView()
            }
        }
    }
}
