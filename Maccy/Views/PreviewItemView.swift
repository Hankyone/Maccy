import KeyboardShortcuts
import SwiftUI

struct PreviewItemView: View {
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
        AsyncView<NSImage?, _, _> {
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
        ScrollView {
          Text(item.text)
            .font(.body)
        }
      }

      Spacer(minLength: 0)

      Divider()
        .padding(.vertical)

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
