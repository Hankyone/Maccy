import AppKit.NSWorkspace
import Defaults
import Foundation
import Observation
import Sauce

@Observable
class HistoryItemDecorator: Identifiable, Hashable, HasVisibility {
  private static let previewMaxParagraphSize = 10_000

  static func == (lhs: HistoryItemDecorator, rhs: HistoryItemDecorator) -> Bool {
    return lhs.id == rhs.id
  }

  static var previewImageSize: NSSize {
    // Cap at 1200px on the longest side — plenty for the slideout preview
    // (typically ~400px wide) even on Retina, but far cheaper to generate
    // than full screen resolution (which was ~3000x2000).
    let maxDimension: CGFloat = 1200
    if let screen = NSScreen.forPopup?.visibleFrame.size {
      let longest = max(screen.width, screen.height)
      let scale = min(1.0, maxDimension / longest)
      return NSSize(width: screen.width * scale, height: screen.height * scale)
    }
    return NSSize(width: 1200, height: 900)
  }
  static var thumbnailImageSize: NSSize { NSSize(width: 340, height: Defaults[.imageMaxHeight]) }

  let id = UUID()

  var title: String = ""
  var attributedTitle: AttributedString?

  var isVisible: Bool = true
  var selectionIndex: Int = -1
  var isSelected: Bool {
    return selectionIndex != -1
  }
  var shortcuts: [KeyShortcut] = []

  // Cached because the LaunchServices lookup is slow and runs on every render.
  @ObservationIgnored
  private(set) lazy var application: String? = {
    if item.universalClipboard {
      return "iCloud"
    }

    guard let bundle = item.application,
      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
    else {
      return nil
    }

    return url.deletingPathExtension().lastPathComponent
  }()

  var hasImage: Bool { item.image != nil }
  var hasFileURLs: Bool { !item.fileURLs.isEmpty }
  var hasPlainText: Bool { item.text != nil }
  var hasRichText: Bool { item.rtf != nil || item.html != nil }

  var previewImageGenerationTask: Task<(), Error>?
  var thumbnailImageGenerationTask: Task<(), Error>?
  var previewImage: NSImage?
  private(set) var previewText = SizedString("")
  var thumbnailImage: NSImage?
  var applicationImage: ApplicationImage

  @ObservationIgnored
  private(set) lazy var imageSize: String? = item.imageData.map {
    ByteCountFormatter.string(fromByteCount: Int64($0.count), countStyle: .file)
  }

  // Full text for search, cached because reading it from storage is slow.
  // Capped so a huge clip can't slow down typing.
  @ObservationIgnored
  private var cachedSearchableText: String?
  var searchableText: String {
    if let cachedSearchableText {
      return cachedSearchableText
    }
    let text = String(item.previewableText.prefix(200_000))
    cachedSearchableText = text
    return text
  }

  // 10k characters seems to be more than enough on large displays
  var text: String { previewText.string.shortened(to: 10_000) }

  var isPinned: Bool { item.pin != nil }
  var isUnpinned: Bool { item.pin == nil }

  func hash(into hasher: inout Hasher) {
    // We need to hash title and attributedTitle, so SwiftUI knows it needs to update the view if they chage
    hasher.combine(id)
    hasher.combine(title)
    hasher.combine(attributedTitle)
  }

  private(set) var item: HistoryItem

  var multiSelectionIndex: Int? {
    guard selectionIndex >= 0, AppState.shared.navigator.isMultiSelectInProgress else {
      return nil
    }
    return selectionIndex
  }

  // Describe the complete item independently of its potentially truncated visual content.
  var accessibilityLabel: String {
    var parts: [String] = []
    if hasImage, let image = item.image {
      let size = image.pixelSize
      parts.append(
        String(
          format: NSLocalizedString("history_item_image_accessibility_label_no_app", comment: ""),
          Int(size.width),
          Int(size.height)
        )
      )
    } else {
      parts.append(title)
    }
    if let application = application {
      parts.append(application)
    }
    if isPinned {
      parts.append(NSLocalizedString("history_item_pinned_accessibility_value", comment: ""))
    }
    if let index = multiSelectionIndex {
      parts.append(
        String(
          format: NSLocalizedString("history_item_selected_accessibility_value", comment: ""),
          index + 1,
          AppState.shared.navigator.selection.count
        )
      )
    }
    return parts.joined(separator: ", ")
  }

  init(_ item: HistoryItem, shortcuts: [KeyShortcut] = []) {
    self.item = item
    self.shortcuts = shortcuts
    self.title = item.title
    self.applicationImage = ApplicationImageCache.shared.getImage(item: item)

    synchronizeItemPin()
    synchronizeItemTitle()
    synchronizeItemText()
  }

  @MainActor
  func ensureThumbnailImage() {
    guard thumbnailImage == nil, thumbnailImageGenerationTask == nil else {
      return
    }
    thumbnailImageGenerationTask = loadImage(
      fitting: HistoryItemDecorator.thumbnailImageSize,
      reserveSpace: true,
      fallback: { [weak self] in self?.generateThumbnailImage() },
      assign: { [weak self] in self?.thumbnailImage = $0 }
    )
  }

  @MainActor
  func ensurePreviewImage() {
    guard previewImage == nil, previewImageGenerationTask == nil else {
      return
    }
    previewImageGenerationTask = loadImage(
      fitting: HistoryItemDecorator.previewImageSize,
      reserveSpace: false,
      fallback: { [weak self] in self?.generatePreviewImage() },
      assign: { [weak self] in self?.previewImage = $0 }
    )
  }

  // Decodes the image at its display size on a background thread, so long
  // histories of screenshots scroll without stalls. When `reserveSpace` is set,
  // an empty image of the final size holds the row height until it's ready.
  @MainActor
  private func loadImage(
    fitting bounds: NSSize,
    reserveSpace: Bool,
    fallback: @escaping @MainActor () -> Void,
    assign: @escaping @MainActor (NSImage) -> Void
  ) -> Task<(), Error>? {
    guard let data = item.imageData else {
      return nil
    }
    guard let size = ImageDownsampler.fittedSize(of: data, in: bounds) else {
      // Image I/O can't read it; let AppKit try.
      return Task { fallback() }
    }

    if reserveSpace {
      assign(NSImage(size: size))
    }

    let scale = NSScreen.forPopup?.backingScaleFactor ?? 2
    return Task {
      let image = await Task.detached(priority: .userInitiated) {
        ImageDownsampler.image(from: data, pointSize: size, backingScale: scale)
      }.value
      try Task.checkCancellation()
      if let image {
        assign(image)
      } else {
        fallback()
      }
    }
  }

  @MainActor
  func asyncGetPreviewImage() async -> NSImage? {
    if let image = previewImage {
      return image
    }
    ensurePreviewImage()
    _ = await previewImageGenerationTask?.result
    return previewImage
  }

  @MainActor
  func cleanupImages() {
    thumbnailImageGenerationTask?.cancel()
    previewImageGenerationTask?.cancel()
    thumbnailImageGenerationTask = nil
    previewImageGenerationTask = nil
    thumbnailImage?.recache()
    previewImage?.recache()
    thumbnailImage = nil
    previewImage = nil
    item.clearDecodedImageCache()
  }

  @MainActor
  private func generateThumbnailImage() {
    guard let image = item.image else {
      return
    }
    thumbnailImage = image.resized(to: HistoryItemDecorator.thumbnailImageSize)
  }

  @MainActor
  private func generatePreviewImage() {
    guard let image = item.image else {
      return
    }
    previewImage = image.resized(to: HistoryItemDecorator.previewImageSize)
  }

  @MainActor
  func sizeImages() {
    generatePreviewImage()
    generateThumbnailImage()
  }

  func highlight(_ query: String, _ ranges: [Range<String.Index>], textRanges: [Range<String.Index>] = []) {
    guard !query.isEmpty else {
      attributedTitle = nil
      return
    }

    if ranges.isEmpty, !textRanges.isEmpty {
      attributedTitle = snippet(around: textRanges)
      return
    }

    guard !title.isEmpty else {
      attributedTitle = nil
      return
    }

    var attributedString = AttributedString(title.shortened(to: 500))
    for range in ranges {
      if let lowerBound = AttributedString.Index(range.lowerBound, within: attributedString),
         let upperBound = AttributedString.Index(range.upperBound, within: attributedString) {
        Self.applyHighlight(to: &attributedString[lowerBound..<upperBound])
      }
    }

    attributedTitle = attributedString
  }

  private static func applyHighlight(to text: inout AttributedSubstring) {
    switch Defaults[.highlightMatch] {
    case .bold:
      text.font = .bold(.body)()
    case .italic:
      text.font = .italic(.body)()
    case .underline:
      text.underlineStyle = .single
    default:
      text.backgroundColor = .findHighlightColor
      text.foregroundColor = .black
    }
  }

  // A one-line excerpt of the full text starting just before the first match,
  // shown in place of the title when the match is past what the title shows.
  private func snippet(around ranges: [Range<String.Index>]) -> AttributedString {
    let text = searchableText
    let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
    guard let first = sorted.first else {
      return AttributedString(title)
    }

    let start = text.index(first.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
    let end = text.index(start, offsetBy: 300, limitedBy: text.endIndex) ?? text.endIndex
    let newline = Defaults[.showSpecialSymbols] ? "⏎" : " "
    func plain(_ part: Substring) -> AttributedString {
      AttributedString(
        part
          .replacingOccurrences(of: "\r\n", with: newline)
          .replacingOccurrences(of: "\n", with: newline)
          .replacingOccurrences(of: "\t", with: " ")
          .removingScalarsUnsafeForTitleLayout()
      )
    }

    var result = AttributedString(start > text.startIndex ? "…" : "")
    var cursor = start
    for range in sorted where range.lowerBound >= cursor && range.upperBound <= end {
      result += plain(text[cursor..<range.lowerBound])
      var match = plain(text[range])
      Self.applyHighlight(to: &match[match.startIndex..<match.endIndex])
      result += match
      cursor = range.upperBound
    }
    result += plain(text[cursor..<end])
    if end < text.endIndex {
      result += AttributedString("…")
    }

    return result
  }

  private func synchronizeItemPin() {
    _ = withObservationTracking {
      item.pin
    } onChange: { [weak self] in
      DispatchQueue.main.async {
        guard let self else { return }
        if let pin = self.item.pin {
          self.shortcuts = KeyShortcut.create(character: pin)
        }
        // History assigns numeric shortcuts when unpinning. Preserve them when
        // this observation callback runs after the history has been updated.
        self.synchronizeItemPin()
      }
    }
  }

  private func synchronizeItemTitle() {
    _ = withObservationTracking {
      item.title
    } onChange: { [weak self] in
      DispatchQueue.main.async {
        guard let self else { return }
        self.title = self.item.title
        self.synchronizeItemTitle()
      }
    }
  }

  private func synchronizeItemText() {
    cachedSearchableText = nil
    previewText = withObservationTracking {
      SizedString(item.previewableText, maxParagraphBytes: Self.previewMaxParagraphSize)
    } onChange: { [weak self] in
      DispatchQueue.main.async { [weak self] in
        self?.synchronizeItemText()
      }
    }
  }
}
