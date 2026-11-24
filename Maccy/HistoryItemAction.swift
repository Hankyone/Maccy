import AppKit
import Defaults
import ImageIO
import UniformTypeIdentifiers

enum HistoryItemAction {
  case unknown
  case copy
  case paste
  case pasteWithoutFormatting

  init(_ modifierFlags: NSEvent.ModifierFlags) {  // swiftlint:disable:this cyclomatic_complexity
    switch modifierFlags {
    case .command where !Defaults[.pasteByDefault]:
      self = .copy
    case .command where Defaults[.pasteByDefault] && !Defaults[.removeFormattingByDefault]:
      self = .paste
    case .command where Defaults[.pasteByDefault] && Defaults[.removeFormattingByDefault]:
      self = .pasteWithoutFormatting
    case .option where !Defaults[.pasteByDefault] && !Defaults[.removeFormattingByDefault]:
      self = .paste
    case .option where !Defaults[.pasteByDefault] && Defaults[.removeFormattingByDefault]:
      self = .pasteWithoutFormatting
    case .option where Defaults[.pasteByDefault] && !Defaults[.removeFormattingByDefault]:
      self = .copy
    case .option where Defaults[.pasteByDefault] && Defaults[.removeFormattingByDefault]:
      self = .copy
    case [.option, .shift] where !Defaults[.pasteByDefault] && !Defaults[.removeFormattingByDefault]:
      self = .pasteWithoutFormatting
    case [.option, .shift] where !Defaults[.pasteByDefault] && Defaults[.removeFormattingByDefault]:
      self = .paste
    case [.command, .shift] where Defaults[.pasteByDefault] && !Defaults[.removeFormattingByDefault]:
      self = .pasteWithoutFormatting
    case [.command, .shift] where Defaults[.pasteByDefault] && Defaults[.removeFormattingByDefault]:
      self = .paste
    default:
      self = .unknown
    }
  }

  var modifierFlags: NSEvent.ModifierFlags {
    switch self {
    case .copy where !Defaults[.pasteByDefault]:
      return .command
    case .paste where Defaults[.pasteByDefault] && !Defaults[.removeFormattingByDefault]:
      return .command
    case .pasteWithoutFormatting where Defaults[.pasteByDefault] && Defaults[.removeFormattingByDefault]:
      return .command
    case .paste where !Defaults[.pasteByDefault] && !Defaults[.removeFormattingByDefault]:
      return .option
    case .pasteWithoutFormatting where !Defaults[.pasteByDefault] && Defaults[.removeFormattingByDefault]:
      return .option
    case .copy where Defaults[.pasteByDefault] && !Defaults[.removeFormattingByDefault]:
      return .option
    case .copy where Defaults[.pasteByDefault] && Defaults[.removeFormattingByDefault]:
      return .option
    case .pasteWithoutFormatting where !Defaults[.pasteByDefault] && !Defaults[.removeFormattingByDefault]:
      return [.option, .shift]
    case .paste where !Defaults[.pasteByDefault] && Defaults[.removeFormattingByDefault]:
      return [.option, .shift]
    case .pasteWithoutFormatting where Defaults[.pasteByDefault] && !Defaults[.removeFormattingByDefault]:
      return [.command, .shift]
    case .paste where Defaults[.pasteByDefault] && Defaults[.removeFormattingByDefault]:
      return [.command, .shift]
    default:
      return []
    }
  }
}

// Extra actions on clips, offered from a clip's context menu and used when
// several clips are selected.
@MainActor
enum ClipActions {
  // Image files are written here so terminals and other apps can read them.
  // Allowed by a sandbox exception in Maccy.entitlements.
  private static let sharedImageDirectory = URL(fileURLWithPath: "/private/tmp/maccy", isDirectory: true)

  static func canPasteAsFilePath(_ item: HistoryItemDecorator) -> Bool {
    item.hasFileURLs || item.hasImage
  }

  static func pasteAsFilePath(_ item: HistoryItemDecorator) {
    if item.hasFileURLs {
      paste(item.item.fileURLs.map(\.path).joined(separator: "\n"))
    } else if let path = writeImageFile(item) {
      paste(path)
    }
  }

  static func recognizedText(_ item: HistoryItemDecorator) -> String? {
    guard item.hasImage, !item.item.title.isEmpty else { return nil }
    return item.item.title
  }

  static func tidyJSON(_ item: HistoryItemDecorator) -> String? {
    guard !item.hasImage, let text = item.item.text else { return nil }
    return prettyJSON(text)
  }

  // Joins the text of the clips, in selection order, into one clip.
  static func combine(_ items: [HistoryItemDecorator], flags: NSEvent.ModifierFlags) {
    let texts = items.compactMap { item -> String? in
      guard !item.hasImage else { return nil }
      return item.item.previewableText.isEmpty ? nil : item.item.previewableText
    }
    guard !texts.isEmpty else { return }

    let action = flags.isEmpty ? (Defaults[.pasteByDefault] ? .paste : .copy) : HistoryItemAction(flags)
    switch action {
    case .copy:
      AppState.shared.popup.close()
      Clipboard.shared.copyInMaccy(texts.joined(separator: "\n"))
      History.shared.searchQuery = ""
    case .paste, .pasteWithoutFormatting:
      paste(texts.joined(separator: "\n"))
    case .unknown:
      return
    }
  }

  static func paste(_ string: String) {
    AppState.shared.popup.close()
    Clipboard.shared.copyInMaccy(string)
    Clipboard.shared.paste()
    History.shared.searchQuery = ""
  }

  private static func writeImageFile(_ item: HistoryItemDecorator) -> String? {
    guard let data = item.item.imageData,
          let source = CGImageSourceCreateWithData(data as CFData, nil) else {
      return nil
    }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let baseName = "clip-\(formatter.string(from: item.item.firstCopiedAt))"

    // Keep PNG and JPEG as they are; convert anything else (such as TIFF) to PNG.
    let sourceType = (CGImageSourceGetType(source) as String?).flatMap { UTType($0) }
    var fileData = data
    var ext = "png"
    if let sourceType, sourceType.conforms(to: .png) || sourceType.conforms(to: .jpeg) {
      ext = sourceType.preferredFilenameExtension ?? "png"
    } else {
      let output = NSMutableData()
      guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
        return nil
      }
      CGImageDestinationAddImageFromSource(destination, source, 0, nil)
      guard CGImageDestinationFinalize(destination) else { return nil }
      fileData = output as Data
    }

    let fileName = "\(baseName).\(ext)"
    for directory in [sharedImageDirectory, URL.temporaryDirectory] {
      do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: fileName)
        try fileData.write(to: url, options: .atomic)
        // Paste the familiar /tmp path rather than /private/tmp.
        return url.path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/")
      } catch {
        continue
      }
    }
    return nil
  }

  // Re-indents valid JSON while keeping keys in their original order.
  static func prettyJSON(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = trimmed.first, first == "{" || first == "[",
          let data = trimmed.data(using: .utf8),
          (try? JSONSerialization.jsonObject(with: data)) != nil else {
      return nil
    }

    let chars = Array(trimmed)
    var output = ""
    var indent = 0
    var inString = false
    var escaped = false
    var index = 0
    func newline() {
      output += "\n" + String(repeating: "  ", count: indent)
    }

    while index < chars.count {
      let char = chars[index]
      index += 1

      if inString {
        output.append(char)
        if escaped {
          escaped = false
        } else if char == "\\" {
          escaped = true
        } else if char == "\"" {
          inString = false
        }
        continue
      }

      switch char {
      case "\"":
        inString = true
        output.append(char)
      case "{", "[":
        var next = index
        while next < chars.count, chars[next].isWhitespace { next += 1 }
        if next < chars.count, chars[next] == (char == "{" ? "}" : "]") {
          output += "\(char)\(chars[next])"
          index = next + 1
        } else {
          output.append(char)
          indent += 1
          newline()
        }
      case "}", "]":
        indent -= 1
        newline()
        output.append(char)
      case ",":
        output.append(char)
        newline()
      case ":":
        output += ": "
      default:
        if !char.isWhitespace {
          output.append(char)
        }
      }
    }

    return output
  }
}
