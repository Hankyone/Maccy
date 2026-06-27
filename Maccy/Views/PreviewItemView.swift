import AppKit
import KeyboardShortcuts
import SwiftUI

struct PreviewItemView: View {
  static var largeTextThreshold = 1_000

  var item: HistoryItemDecorator

  @ViewBuilder
  func previewImage(content: () -> some View) -> some View {
    content()
      .aspectRatio(contentMode: .fit)
      .clipShape(.rect(cornerRadius: 5))
  }

  private func openInPreview() {
    guard let data = item.item.imageData else { return }

    let imageTypes: Set<String> = [
      NSPasteboard.PasteboardType.png.rawValue,
      NSPasteboard.PasteboardType.tiff.rawValue,
      "public.jpeg",
      "public.heic"
    ]
    let ext = item.item.contents.first(where: { imageTypes.contains($0.type) })?.type ?? "tiff"
    let fileExt: String
    switch ext {
    case NSPasteboard.PasteboardType.png.rawValue: fileExt = "png"
    case NSPasteboard.PasteboardType.tiff.rawValue: fileExt = "tiff"
    case "public.jpeg": fileExt = "jpg"
    case "public.heic": fileExt = "heic"
    default: fileExt = "tiff"
    }

    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("maccy-preview-\(UUID().uuidString).\(fileExt)")

    do {
      try data.write(to: tempURL)
      NSWorkspace.shared.open(tempURL)
    } catch {
      // Fallback: convert via NSImage to TIFF
      guard let image = item.item.image,
            let tiffData = image.tiffRepresentation else { return }
      let tiffURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("maccy-preview-\(UUID().uuidString).tiff")
      try? tiffData.write(to: tiffURL)
      NSWorkspace.shared.open(tiffURL)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if item.hasImage {
        AsyncView<NSImage?, _, _>(id: item.id) {
          return await item.asyncGetPreviewImage()
        } content: { image in
          if let image = image {
            previewImage {
              Image(nsImage: image)
                .resizable()
            }
            .onTapGesture(count: 2) {
              openInPreview()
            }
            .onHover { inside in
              if inside {
                NSCursor.pointingHand.push()
              } else {
                NSCursor.pop()
              }
            }
            .help("Double-click to open in Preview")
          } else {
            previewImage {
              ZStack {
                Color.gray.opacity(0.3)
                  .frame(
                    idealWidth: HistoryItemDecorator.previewImageSize.width,
                    idealHeight: HistoryItemDecorator.previewImageSize.height
                  )
                Image(systemName: "photo.badge.exclamationmark")
                  .symbolRenderingMode(.multicolor)
                  .frame(alignment: .center)
              }
            }
          }
        } placeholder: {
          previewImage {
            ZStack {
              Color.gray.opacity(0.3)
                .frame(
                  idealWidth: HistoryItemDecorator.previewImageSize.width,
                  idealHeight: HistoryItemDecorator.previewImageSize.height
                )
              ProgressView()
                .frame(alignment: .center)
            }
          }
        }
        .id(item.id)
      } else {
        let text = item.previewText
        if text.count >= Self.largeTextThreshold {
          LargeTextPreviewView(text: text)
            .id("textpreview-\(item.id)")
        } else {
          ScrollView {
            Text(text)
              .font(.body)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxWidth: .infinity)
        }
      }

      Spacer(minLength: 0)

      Divider()
        .padding(.bottom)

      if let application = item.application {
        HStack(spacing: 3) {
          Text("Application", tableName: "PreviewItemView")
          AppImageView(
            appImage: item.applicationImage,
            size: NSSize(width: 11, height: 11)
          )
          Text(application)
        }
      }

      if item.hasImage, let image = item.item.image {
        HStack(spacing: 3) {
          Text("Dimensions", tableName: "PreviewItemView")
          Text("\(Int(image.pixelSize.width))×\(Int(image.pixelSize.height))")
        }
      }

      HStack(spacing: 3) {
        Text("FirstCopyTime", tableName: "PreviewItemView")
        Text(item.item.firstCopiedAt, style: .date)
        Text(item.item.firstCopiedAt, style: .time)
      }

      HStack(spacing: 3) {
        Text("LastCopyTime", tableName: "PreviewItemView")
        Text(item.item.lastCopiedAt, style: .date)
        Text(item.item.lastCopiedAt, style: .time)
      }

      HStack(spacing: 3) {
        Text("NumberOfCopies", tableName: "PreviewItemView")
        Text(String(item.item.numberOfCopies))
      }
    }
    .controlSize(.small)
  }
}

struct LargeTextPreviewView: NSViewRepresentable {
  let text: String

  func makeNSView(context: Context) -> NSScrollView {
    return Self.makeScrollView(text: text)
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? NSTextView, textView.string != text else {
      return
    }

    textView.string = text
  }

  static func makeScrollView(text: String) -> NSScrollView {
    let textView = NSTextView(usingTextLayoutManager: true)
    textView.isEditable = false
    textView.isSelectable = false
    textView.isRichText = false
    textView.drawsBackground = false
    textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    textView.textColor = .labelColor
    textView.textContainerInset = .zero
    textView.minSize = .zero
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.heightTracksTextView = false
    textView.string = text

    let scrollView = NSScrollView()
    scrollView.documentView = textView
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false
    return scrollView
  }
}
