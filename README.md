# WatchFolder

Keep an eye on a folder and know what changes—even when files are renamed, edited in place, or saved atomically.

WatchFolder is a lightweight macOS app that periodically scans a folder and its ordinary subfolders, records changes in a readable log, and can send a macOS notification for each event. Pick a folder, start watching, and follow the live event list right in the app.

## What it does

- Detects files and folders being added or removed.
- Recognizes renames by matching filesystem device and inode identity.
- Detects in-place edits and replacements using identity, file size, and modification time.
- Recursively watches ordinary directories; treats app bundles and other packages as single items.
- Writes timestamped events to `watchfolder.log` in the watched folder.
- Prevents another WatchFolder instance from watching the same folder at the same time.
- Ignores its own log and lock files, `.DS_Store`, and AppleDouble `._*` metadata files.
- Remembers the last selected folder between launches.

> **Polling, not a backup:** WatchFolder checks the folder every 0.5 seconds by default. Very short-lived changes between scans may not be observed. It reports changes; it does not preserve, restore, or synchronize files.

## Requirements

- macOS 13 or later
- Swift 5.9 or later and the Xcode Command Line Tools
- The packaged app build script targets Apple Silicon (`arm64`)

## Build and run

Clone the repository, then from its root:

```sh
./build_app.sh
open build/WatchFolder.app
```

The packaged app loads `Resources/AppIcon.icns` as its application icon, which
macOS uses for Notification Center notifications. Launch the rebuilt `.app`
bundle this way; running the executable directly with `swift run WatchFolder`
does not provide an app bundle icon and may show a generic notification icon.

To run the executable directly for development (without the packaged app):

```sh
swift run WatchFolder
```

The build script compiles the app for arm64, assembles the app bundle with
`Resources/AppIcon.icns`, and ad-hoc signs it. It recreates
`build/WatchFolder.app` when run.

## Use

1. Launch WatchFolder and choose a folder.
2. Select **Start Watching**. The first run may ask permission to send notifications.
3. Keep the app open to view events as they are detected. Use **Stop** to end the watch.
4. Choose **Reveal Log** to open `watchfolder.log` in Finder (or open the folder if the log does not exist yet).

Watching still works if notifications are unavailable or declined; the app displays a notice and continues logging events.

Use **Install** to install a per-user LaunchAgent that runs the app's primary
executable in background-service mode and immediately watches the selected
folder after the app closes. Using the primary app executable allows macOS to
associate service notifications with WatchFolder. The app asks for notification
permission if needed and explains why it is closing before it exits. Reopening
the app while the service is installed shows and refreshes the shared event log.
**Uninstall** stops and removes the service and its app copy. The service does not resume
monitoring automatically at the next login. After logging in again, use
**Uninstall** and then **Install** to start it again.

## Event log

The watcher creates or appends to `watchfolder.log` inside the selected folder. Each UTF-8 line contains an ISO 8601 timestamp with fractional seconds followed by one of:

```text
2026-10-30T18:48:52.505Z Added: reports/summary.txt
2026-10-30T18:48:53.010Z Renamed: draft.txt -> final.txt
2026-10-30T18:48:53.515Z Modified: settings.json
2026-10-30T18:48:54.020Z Removed: old.txt
```

The log and `.watchfolder.lock` are created in the selected folder. The lock is released when watching stops or the app exits.

## Development

The project is a Swift Package with separate core, GUI, and self-test executable targets:

```sh
swift build
swift run SelfTests
```

`SelfTests` exits with status 0 when all checks pass. The core is in `Sources/WatchFolderCore`; the SwiftUI app is in `Sources/WatchFolder`.

## License

WatchFolder is available under the [MIT License](LICENSE).
