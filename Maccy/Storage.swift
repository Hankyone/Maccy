import Foundation
import SwiftData

@MainActor
class Storage {
  static let shared = Storage()

  var container: ModelContainer
  var context: ModelContext { container.mainContext }
  var size: String {
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).allValues.first?.value as? Int64, size > 1 else {
      return ""
    }

    return ByteCountFormatter().string(fromByteCount: size)
  }

  private let url: URL

  init() {
    // URL.applicationSupportDirectory returns the container path on macOS 27,
    // even without sandbox entitlements. Use getpwuid to get the real home
    // directory so we can find the existing database at the standard path.
    var realHome = NSHomeDirectory()
    if let pw = getpwuid(getuid()) {
      realHome = String(cString: pw.pointee.pw_dir)
    }
    url = URL(fileURLWithPath: realHome)
      .appendingPathComponent("Library/Application Support/Maccy/Storage.sqlite")

    // One-time migration: copy the database from the old sandboxed container
    // (org.p0deje.Maccy) to the real Application Support directory.
    let migrationsKey = "storage-db-migrated"
    if !UserDefaults.standard.bool(forKey: migrationsKey) {
      let oldContainerDB = URL(fileURLWithPath: realHome)
        .appendingPathComponent("Library/Containers/org.p0deje.Maccy/Data/Library/Application Support/Maccy/")

      let fm = FileManager.default
      let dbFiles = ["Storage.sqlite", "Storage.sqlite-shm", "Storage.sqlite-wal"]
      var copied = false

      for file in dbFiles {
        let src = oldContainerDB.appendingPathComponent(file)
        let dst = url.deletingLastPathComponent().appendingPathComponent(file)
        if fm.fileExists(atPath: src.path) {
          // Only copy if the destination doesn't have real data yet
          if !copied {
            // Remove existing files first
            for f in dbFiles {
              try? fm.removeItem(at: url.deletingLastPathComponent().appendingPathComponent(f))
            }
            copied = true
          }
          do {
            try fm.copyItem(at: src, to: dst)
            NSLog("Maccy DB migration: copied \(file)")
          } catch {
            NSLog("Maccy DB migration: failed to copy \(file): \(error)")
          }
        }
      }

      if !copied {
        NSLog("Maccy DB migration: no old DB found to copy")
      }
      UserDefaults.standard.set(true, forKey: migrationsKey)
    }

    var config = ModelConfiguration(url: url)

    #if DEBUG
    if CommandLine.arguments.contains("enable-testing") {
      config = ModelConfiguration(isStoredInMemoryOnly: true)
    }
    #endif

    do {
      container = try ModelContainer(for: HistoryItem.self, configurations: config)
    } catch let error {
      fatalError("Cannot load database: \(error.localizedDescription).")
    }
  }
}
