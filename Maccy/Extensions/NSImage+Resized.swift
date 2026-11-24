import AppKit.NSImage
import ImageIO

// Based on https://stackoverflow.com/questions/73062803/resizing-nsimage-keeping-aspect-ratio-reducing-the-image-size-while-trying-to-sc.
extension NSImage {
  /// Returns the pixel dimensions of the image.
  /// On Retina displays, this differs from `size` which returns logical points.
  var pixelSize: NSSize {
    if let bitmapRep = representations.first(where: { $0 is NSBitmapImageRep }) as? NSBitmapImageRep {
      return NSSize(width: CGFloat(bitmapRep.pixelsWide), height: CGFloat(bitmapRep.pixelsHigh))
    }
    // Fallback to logical size if no bitmap representation is available
    return size
  }
  func resized(to newSize: NSSize) -> NSImage {
    let ratioX = newSize.width / size.width
    let ratioY = newSize.height / size.height
    let ratio = ratioX < ratioY ? ratioX : ratioY
    let newHeight = size.height * ratio
    let newWidth = size.width * ratio
    let newSize = NSSize(width: newWidth, height: newHeight)

    // Don't attempt to size up.
    if newSize.height >= size.height {
      return self
    }

    return NSImage(size: newSize, flipped: false) { destRect in
      if let context = NSGraphicsContext.current {
        context.imageInterpolation = .high
        self.draw(in: destRect, from: NSRect.zero, operation: .copy, fraction: 1)
      }

      return true
    }
  }
}

/// Fast, memory-light image downsampling with Image I/O. Safe to call off the main thread.
nonisolated enum ImageDownsampler {
  /// Size, in points, that the image at `data` takes when fitted into `bounds` without upscaling.
  /// Reads only the image header.
  static func fittedSize(of data: Data, in bounds: NSSize) -> NSSize? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          var width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
          var height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
          width > 0, height > 0 else {
      return nil
    }

    // EXIF orientations 5-8 rotate the image by 90 degrees.
    if let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, orientation >= 5 {
      swap(&width, &height)
    }

    // Convert pixels to points the same way NSImage does, using the image's DPI.
    let dpi = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
    let scale = dpi > 0 ? 72 / dpi : 1
    let size = NSSize(width: width * scale, height: height * scale)

    let ratio = min(1, bounds.width / size.width, bounds.height / size.height)
    return NSSize(width: (size.width * ratio).rounded(), height: (size.height * ratio).rounded())
  }

  /// Decodes `data` straight to an image of `pointSize`, rendered at `backingScale` pixels per point.
  static func image(from data: Data, pointSize: NSSize, backingScale: CGFloat) -> NSImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
      return nil
    }

    let maxPixelSize = max(pointSize.width, pointSize.height) * max(backingScale, 1)
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixelSize.rounded()))
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      return nil
    }

    return NSImage(cgImage: cgImage, size: pointSize)
  }
}
