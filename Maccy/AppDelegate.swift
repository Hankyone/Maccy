import Defaults
import KeyboardShortcuts
import Sparkle
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
  var panel: FloatingPanel<ContentView>!

  // Start Sparkle's updater at launch so it can check for updates
  // and prompt the user. Without this, the updater only runs when
  // the Settings window is opened, which means no automatic checks.
  let updater = SoftwareUpdater()

  @objc
  private lazy var statusItem: NSStatusItem = {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.behavior = .removalAllowed
    statusItem.button?.action = #selector(performStatusItemClick)
    statusItem.button?.image = Defaults[.menuIcon].image
    statusItem.button?.imagePosition = .imageLeft
    statusItem.button?.target = self
    return statusItem
  }()

  private var isStatusItemDisabled: Bool {
    Defaults[.ignoreEvents] || Defaults[.enabledPasteboardTypes].isEmpty
  }

  private var statusItemVisibilityObserver: NSKeyValueObservation?

  func applicationWillFinishLaunching(_ notification: Notification) { // swiftlint:disable:this function_body_length
    #if DEBUG
    if CommandLine.arguments.contains("enable-testing") {
      SPUUpdater(hostBundle: Bundle.main,
                 applicationBundle: Bundle.main,
                 userDriver: SPUStandardUserDriver(hostBundle: Bundle.main, delegate: nil),
                 delegate: nil)
      .automaticallyChecksForUpdates = false
    }
    #endif

    // Bridge FloatingPanel via AppDelegate.
    AppState.shared.appDelegate = self

    Clipboard.shared.onNewCopy { History.shared.add($0) }
    Clipboard.shared.start()

    Task {
      for await _ in Defaults.updates(.clipboardCheckInterval, initial: false) {
        Clipboard.shared.restart()
      }
    }

    statusItemVisibilityObserver = observe(\.statusItem.isVisible, options: .new) { _, change in
      if let newValue = change.newValue, Defaults[.showInStatusBar] != newValue {
        Defaults[.showInStatusBar] = newValue
      }
    }

    Task {
      for await value in Defaults.updates(.showInStatusBar) {
        statusItem.isVisible = value
      }
    }

    Task {
      for await value in Defaults.updates(.menuIcon, initial: false) {
        statusItem.button?.image = value.image
      }
    }

    synchronizeMenuIconText()
    Task {
      for await value in Defaults.updates(.showRecentCopyInMenuBar) {
        if value {
          statusItem.button?.title = AppState.shared.menuIconText
        } else {
          statusItem.button?.title = ""
        }
      }
    }

    Task {
      for await _ in Defaults.updates(.ignoreEvents) {
        statusItem.button?.appearsDisabled = isStatusItemDisabled
      }
    }

    Task {
      for await _ in Defaults.updates(.enabledPasteboardTypes) {
        statusItem.button?.appearsDisabled = isStatusItemDisabled
      }
    }
  }

  func applicationDidFinishLaunching(_ aNotification: Notification) {
    migrateUserDefaults()
    disableUnusedGlobalHotkeys()

    panel = FloatingPanel(
      contentRect: NSRect(origin: .zero, size: Defaults[.windowSize]),
      identifier: Bundle.main.bundleIdentifier ?? "ca.anouar.maccypu",
      statusBarButton: statusItem.button,
      onClose: { AppState.shared.popup.reset() }
    ) {
      ContentView()
    }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    panel.toggle(height: AppState.shared.popup.height)
    return true
  }

  func applicationWillTerminate(_ notification: Notification) {
    if Defaults[.clearOnQuit] {
      AppState.shared.history.clear()
    }
  }

  private func migrateUserDefaults() {
    // One-time migration from old bundle ID (org.p0deje.Maccy) to new (ca.anouar.maccypu)
    if Defaults[.migrations]["bundle-id-migration"] != true {
      // NSHomeDirectory() returns the container path on macOS 27, even without
      // sandbox entitlements. Use getpwuid to get the real home directory.
      var realHome = NSHomeDirectory()
      if let pw = getpwuid(getuid()) {
        realHome = String(cString: pw.pointee.pw_dir)
      }
      let oldPrefsURL = URL(fileURLWithPath: realHome)
        .appendingPathComponent("Library/Preferences/org.p0deje.Maccy.plist")

      NSLog("Maccy migration: NSHomeDirectory=%@, realHome=%@, oldPrefsPath=%@, exists=%d",
            NSHomeDirectory(), realHome, oldPrefsURL.path,
            FileManager.default.fileExists(atPath: oldPrefsURL.path))

      // Also write to a debug file since NSLog may be filtered
      let debugLog = "NSHomeDirectory=\(NSHomeDirectory())\nrealHome=\(realHome)\noldPrefsPath=\(oldPrefsURL.path)\nexists=\(FileManager.default.fileExists(atPath: oldPrefsURL.path))\n"
      try? debugLog.write(toFile: "/tmp/maccy-migration-debug.log", atomically: true, encoding: .utf8)

      var migrated = false
      if FileManager.default.fileExists(atPath: oldPrefsURL.path),
         let oldPrefs = NSDictionary(contentsOf: oldPrefsURL) as? [String: Any] {
        NSLog("Maccy migration: found %d keys in old prefs", oldPrefs.count)
        let keysToMigrate = [
          "KeyboardShortcuts_pin",
          "KeyboardShortcuts_popup",
          "KeyboardShortcuts_delete",
          "KeyboardShortcuts_togglePreview",
          "windowSize",
          "previewWidth",
          "showSearch",
          "showTitle",
          "showFooter",
          "menuIcon",
          "pasteByDefault",
          "removeFormattingByDefault",
          "searchMode",
          "searchVisibility",
          "enabledPasteboardTypes",
          "ignoredApps",
          "popupPosition",
          "popupScreen",
          "pinTo",
          "previewDelay",
          "imageMaxHeight",
          "highlightMatch",
          "showApplicationIcons",
          "clearOnQuit",
          "avoidTakingFocus",
          "saratovSeparator"
        ]
        var migratedCount = 0
        for key in keysToMigrate {
          if let value = oldPrefs[key] {
            UserDefaults.standard.set(value, forKey: key)
            migratedCount += 1
          }
        }
        NSLog("Maccy migration: migrated %d keys", migratedCount)
        try? "migrated \(migratedCount) keys\n".write(toFile: "/tmp/maccy-migration-debug.log", atomically: true, encoding: .utf8)
        migrated = true
      } else {
        NSLog("Maccy migration: could not read old prefs file")
        try? "could not read old prefs file\n".write(toFile: "/tmp/maccy-migration-debug.log", atomically: true, encoding: .utf8)
      }
      // Only mark migration as done if we successfully read the old prefs.
      // If the file couldn't be read (e.g. containerized filesystem restrictions),
      // we'll retry on next launch.
      if migrated {
        Defaults[.migrations]["bundle-id-migration"] = true
      }
    } else {
      NSLog("Maccy migration: already done, skipping")
    }

    if Defaults[.migrations]["2024-07-01-version-2"] != true {
      // Start 2.x from scratch.
      Defaults.reset(.migrations)

      // Inverse hide* configuration keys.
      Defaults[.showFooter] = !UserDefaults.standard.bool(forKey: "hideFooter")
      Defaults[.showSearch] = !UserDefaults.standard.bool(forKey: "hideSearch")
      Defaults[.showTitle] = !UserDefaults.standard.bool(forKey: "hideTitle")
      UserDefaults.standard.removeObject(forKey: "hideFooter")
      UserDefaults.standard.removeObject(forKey: "hideSearch")
      UserDefaults.standard.removeObject(forKey: "hideTitle")

      Defaults[.migrations]["2024-07-01-version-2"] = true
    }

    // The following defaults are not used in Maccy 2.x
    // and should be removed in 3.x.
    // - LaunchAtLogin__hasMigrated
    // - avoidTakingFocus
    // - saratovSeparator
    // - maxMenuItemLength
    // - maxMenuItems
  }

  @objc
  private func performStatusItemClick() {
    if let event = NSApp.currentEvent {
      let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

      if modifierFlags.contains(.option) {
        Defaults[.ignoreEvents].toggle()

        if modifierFlags.contains(.shift) {
          Defaults[.ignoreOnlyNextEvent] = Defaults[.ignoreEvents]
        }

        return
      }
    }

    panel.toggle(height: AppState.shared.popup.height, at: .statusItem)
  }

  private func synchronizeMenuIconText() {
    _ = withObservationTracking {
      AppState.shared.menuIconText
    } onChange: {
      DispatchQueue.main.async {
        if Defaults[.showRecentCopyInMenuBar] {
          self.statusItem.button?.title = AppState.shared.menuIconText
        }
        self.synchronizeMenuIconText()
      }
    }
  }

  private func disableUnusedGlobalHotkeys() {
    let names: [KeyboardShortcuts.Name] = [.delete, .pin]
    KeyboardShortcuts.disable(names)

    NotificationCenter.default.addObserver(
      forName: Notification.Name("KeyboardShortcuts_shortcutByNameDidChange"),
      object: nil,
      queue: nil
    ) { notification in
      if let name = notification.userInfo?["name"] as? KeyboardShortcuts.Name, names.contains(name) {
        KeyboardShortcuts.disable(name)
      }
    }
  }
}
