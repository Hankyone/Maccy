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
