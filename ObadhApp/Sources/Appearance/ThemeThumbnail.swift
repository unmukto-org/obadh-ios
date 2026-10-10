import SwiftUI
import UIKit

/// The same keyboard as the detail preview, at the same aspect ratio. Native
/// glass is rendered on screen before taking UIKit's composited snapshot.
/// drawHierarchy/layer.render can alter its material. Cards retain snapshots
/// rather than dozens of live effects.
struct ThemeThumbnail: View {
  let appearance: KeyboardAppearance
  var photo: CGImage? = nil
  @State private var visible = false

  var body: some View {
    ThemeThumbnailContent(appearance: appearance, photo: photo, active: visible)
      .onAppear { visible = true }
      .onDisappear { visible = false }
  }
}

private struct ThemeThumbnailContent: UIViewRepresentable {
  let appearance: KeyboardAppearance
  let photo: CGImage?
  let active: Bool

  func makeUIView(context: Context) -> ThemeThumbnailView { ThemeThumbnailView() }
  func updateUIView(_ view: ThemeThumbnailView, context: Context) {
    view.display(appearance, photo: photo, active: active)
  }
  static func dismantleUIView(_ view: ThemeThumbnailView, coordinator: ()) {
    view.stopDisplaying()
  }
}

@MainActor
final class ThemeThumbnailView: UIView {
  private static let cache: NSCache<NSString, UIView> = {
    let cache = NSCache<NSString, UIView>()
    cache.totalCostLimit = 12 * 1024 * 1024
    cache.countLimit = 96
    return cache
  }()
  private var artwork: UIView?
  private var preview: KeyboardThemePreviewView?
  private var appearance: KeyboardAppearance?
  private var photo: CGImage?
  private var active = false
  private var renderedKey: String?
  private var captureTask: Task<Void, Never>?

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    accessibilityElementsHidden = true
    registerForTraitChanges([
      UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self, UITraitDisplayScale.self,
    ]) { (view: ThemeThumbnailView, _) in view.invalidate() }
    NotificationCenter.default.addObserver(self, selector: #selector(transparencyDidChange(_:)),
      name: UIAccessibility.reduceTransparencyStatusDidChangeNotification,
      object: nil)
  }
  required init?(coder: NSCoder) { fatalError("Unused") }
  deinit {
    captureTask?.cancel()
    NotificationCenter.default.removeObserver(self)
  }
  @objc nonisolated private func transparencyDidChange(_ notification: Notification) {
    Task { @MainActor [weak self] in self?.invalidate() }
  }

  func display(_ appearance: KeyboardAppearance, photo: CGImage?, active: Bool) {
    let changed = self.appearance != appearance || self.photo !== photo
    self.appearance = appearance
    self.photo = photo
    self.active = active
    if !active {
      stopDisplaying()
    } else if changed {
      invalidate()
    } else {
      setNeedsLayout()
    }
  }
  func stopDisplaying() {
    active = false
    captureTask?.cancel()
    captureTask = nil
    preview?.removeFromSuperview()
    preview = nil
    artwork?.removeFromSuperview()
    artwork = nil
    renderedKey = nil
  }
  private func invalidate() {
    captureTask?.cancel()
    captureTask = nil
    preview?.removeFromSuperview()
    preview = nil
    artwork?.removeFromSuperview()
    artwork = nil
    renderedKey = nil
    setNeedsLayout()
  }
  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil {
      invalidate()
    } else {
      setNeedsLayout()
    }
  }
  override func layoutSubviews() {
    super.layoutSubviews()
    artwork?.frame = bounds
    guard active, window != nil, bounds.width > 0, bounds.height > 0,
      let appearance else { return }
    let scale = traitCollection.displayScale
    let photoRevision: String = appearance.photoID == nil
      ? "" : (appearance.revision?.uuidString ?? "loading")
    let components: [String] = [
      appearance.themeID, appearance.mode.rawValue, String(appearance.keyOutlines),
      photoRevision,
      String(traitCollection.userInterfaceStyle.rawValue),
      String(traitCollection.accessibilityContrast.rawValue),
      String(UIAccessibility.isReduceTransparencyEnabled), String(Double(scale)),
      String(Int((bounds.width * scale).rounded())),
      String(Int((bounds.height * scale).rounded())),
    ]
    let key = components.joined(separator: "/")
    guard renderedKey != key else { return }
    captureTask?.cancel()
    captureTask = nil
    preview?.removeFromSuperview()
    preview = nil
    artwork?.removeFromSuperview()
    artwork = nil
    renderedKey = key
    let cacheable = appearance.photoID == nil || (photo != nil && appearance.revision != nil)
    if cacheable, let template = Self.cache.object(forKey: key as NSString),
      let snapshot = template.snapshotView(afterScreenUpdates: false) {
      show(snapshot)
      return
    }
    let live = KeyboardThemePreviewView()
    preview = live
    addSubview(live)
    live.frame = bounds
    live.display(appearance, photo: photo)
    live.layoutIfNeeded()
    captureTask = Task { @MainActor [weak self, weak live] in
      // Let UIKit composite the real glass before capturing. A failed snapshot
      // keeps the live preview; it never caches an empty keyboard.
      do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
      guard let self, let live, !Task.isCancelled, self.active,
        self.window != nil, self.renderedKey == key else { return }
      self.captureTask = nil
      guard let template = live.snapshotView(afterScreenUpdates: true),
        let snapshot = template.snapshotView(afterScreenUpdates: false) else { return }
      if cacheable {
        let pixels = Int((live.bounds.width * scale).rounded())
          * Int((live.bounds.height * scale).rounded())
        Self.cache.setObject(template, forKey: key as NSString, cost: pixels * 4)
      }
      self.show(snapshot)
      live.removeFromSuperview()
      self.preview = nil
    }
  }
  private func show(_ snapshot: UIView) {
    artwork?.removeFromSuperview()
    artwork = snapshot
    snapshot.frame = bounds
    snapshot.isUserInteractionEnabled = false
    addSubview(snapshot)
  }
}
