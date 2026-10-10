#if canImport(UIKit)
  import UIKit
  import ImageIO

  extension ThemeColor {
    var uiColor: UIColor { UIColor(red: red, green: green, blue: blue, alpha: 1) }
  }

  /// Artwork is content beneath the native glass layer, never a substitute material.
  @MainActor
  final class KeyboardThemeBackdropView: UIView {
    private let gradient = CAGradientLayer()
    private let artwork = CALayer()
    private let scrim = CALayer()
    private let materialBlendMask = CAGradientLayer()
    private var nativeSuggestionBandHeight: CGFloat = 0
    private var revealHeight: CGFloat = 1
    override init(frame: CGRect) {
      super.init(frame: frame)
      isUserInteractionEnabled = false
      layer.addSublayer(gradient)
      layer.addSublayer(artwork)
      layer.addSublayer(scrim)
      gradient.startPoint = CGPoint(x: 0.5, y: 0)
      gradient.endPoint = CGPoint(x: 0.5, y: 1)
      artwork.contentsGravity = .resizeAspectFill
      artwork.masksToBounds = true
      artwork.minificationFilter = .linear
      artwork.magnificationFilter = .linear
      materialBlendMask.startPoint = CGPoint(x: 0.5, y: 0)
      materialBlendMask.endPoint = CGPoint(x: 0.5, y: 1)
      materialBlendMask.colors = [
        UIColor.clear.cgColor,
        UIColor.clear.cgColor,
        UIColor.black.cgColor,
        UIColor.black.cgColor,
      ]
    }
    required init?(coder: NSCoder) { fatalError("Unused") }
    override func layoutSubviews() {
      super.layoutSubviews()
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      for item in [gradient, artwork, scrim] { item.frame = bounds }
      updateMaterialBlendMask()
      CATransaction.commit()
    }
    /// Leave the suggestion strip on the same native material as the iOS-owned
    /// band above it. Reveal artwork only in the gap before the first key row.
    func alignWithNativeSuggestionBand(height: CGFloat, revealHeight: CGFloat) {
      nativeSuggestionBandHeight = max(0, height)
      self.revealHeight = max(1, revealHeight)
      layer.mask = materialBlendMask
      updateMaterialBlendMask()
    }
    private func updateMaterialBlendMask() {
      materialBlendMask.frame = bounds
      guard bounds.height > 0 else { return }
      let start = min(bounds.height, nativeSuggestionBandHeight)
      let end = min(bounds.height, start + revealHeight)
      materialBlendMask.locations = [0,
        NSNumber(value: start / bounds.height),
        NSNumber(value: end / bounds.height), 1]
    }
    func display(preset: KeyboardThemePreset?, photo: CGImage?, palette: KeyboardThemePalette?,
      editingCrop: ThemePhotoCrop? = nil, editingBrightness: Double = 1) {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      defer { CATransaction.commit() }
      isHidden = palette == nil
      backgroundColor = editingCrop != nil ? .black
        : (preset.map { ThemeColor($0.palette[0]).uiColor } ?? .clear)
      gradient.isHidden = preset?.gradient.isEmpty != false || preset?.mesh.isEmpty == false
      gradient.colors = preset?.gradient.map { ThemeColor($0).uiColor.cgColor }
      gradient.locations = preset?.positions.map { NSNumber(value: $0) }
      artwork.contents = photo
      if let editingCrop, let photo {
        let rect = editingCrop.rectangle(imageWidth: Double(photo.width),
          imageHeight: Double(photo.height))
        artwork.contentsRect = CGRect(x: rect.x, y: rect.y, width: rect.width,
          height: rect.height)
        artwork.contentsGravity = .resize
        artwork.opacity = Float(min(1, max(0, editingBrightness)))
      } else {
        artwork.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        artwork.contentsGravity = .resizeAspectFill
        artwork.opacity = 1
      }
      if let mesh = preset?.mesh, !mesh.isEmpty {
        let side = Int(Double(mesh.count).squareRoot())
        var bytes = mesh.flatMap { color -> [UInt8] in
          [UInt8((color >> 16) & 255), UInt8((color >> 8) & 255), UInt8(color & 255), 255]
        }
        if side * side == mesh.count, let provider = CGDataProvider(data: Data(bytes) as CFData) {
          artwork.contents = CGImage(
            width: side, height: side, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent)
          artwork.contentsGravity = .resize
          let inset = 0.5 / Double(side)
          artwork.contentsRect = CGRect(
            x: inset, y: inset, width: 1 - 2 * inset, height: 1 - 2 * inset)
        }
        bytes.removeAll()
      }
      artwork.isHidden = artwork.contents == nil
      if let palette {
        scrim.backgroundColor =
          palette.surface.uiColor.withAlphaComponent(palette.backdropScrimOpacity).cgColor
      } else {
        scrim.backgroundColor = nil
      }
    }
  }

  enum KeyboardThemeImage {
    /// Bounded decode, EXIF orientation applied, with no full-resolution raster.
    static func decode(_ url: URL, maxSide: Int = 1280) -> CGImage? {
      guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
        let size = attributes[.size] as? NSNumber, size.int64Value <= 100_000_000,
        let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
        let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
        width.doubleValue > 0, height.doubleValue > 0,
        width.doubleValue * height.doubleValue <= 100_000_000
      else { return nil }
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxSide, kCGImageSourceShouldCacheImmediately: true,
      ]
      return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
  }
#endif
