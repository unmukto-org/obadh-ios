import SwiftUI

struct ThemePhotoEditor: View {
  let draft: ThemePhotoDraft
  let saved: (KeyboardPhotoTheme) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var crop: ThemePhotoCrop
  @State private var brightness: Double
  @State private var original: CGImage?
  @State private var preview: CGImage?
  @State private var dragStart: ThemePhotoCrop?
  @State private var zoomStart: Double?
  @State private var saving = false
  @State private var decodeFailed = false
  private let outlines = KeyboardPreferences().appearance.keyOutlines
  @State private var error: String?
  @State private var saveTask: Task<Void, Never>?
  private var trimmedName: String {
    String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
  }
  init(draft: ThemePhotoDraft, saved: @escaping (KeyboardPhotoTheme) -> Void) {
    self.draft = draft
    self.saved = saved
    _name = State(initialValue: draft.existing?.name ?? "My Photo")
    _crop = State(initialValue: draft.existing?.crop ?? .init())
    _brightness = State(initialValue: draft.existing?.brightness ?? 0.65)
  }
  var body: some View {
    NavigationStack {
      Form {
        Section {
          if let original {
            cropView(original).aspectRatio(ThemePhotoCrop.aspectRatio, contentMode: .fit)
              .listRowInsets(EdgeInsets())
          } else if decodeFailed {
            Text("This photo couldn’t be opened.").foregroundStyle(.secondary)
          } else {
            ProgressView("Preparing Photo…")
          }
        } footer: {
          Text("Drag to reposition. Pinch to zoom, or use the controls below.")
        }
        Section("Keyboard Preview") {
          ThemePreview(
            appearance: .init(
              themeID: "photo." + (draft.existing?.id ?? draft.id).uuidString, keyOutlines: outlines
            ), photo: preview
          )
          .aspectRatio(414.0 / 280.0, contentMode: .fit).listRowInsets(EdgeInsets())
        }
        Section {
          TextField("Theme Name", text: $name).accessibilityIdentifier("photo-theme-name")
            .onChange(of: name) { _, value in
              if value.count > 80 { name = String(value.prefix(80)) }
            }
        }
        Section("Framing") {
          control("Zoom", value: $crop.zoom, range: 1...4)
          control("Horizontal Position", value: $crop.centerX, range: 0...1)
          control("Vertical Position", value: $crop.centerY, range: 0...1)
          Button("Reset Crop") { crop = .init() }
        }
        Section {
          control("Brightness", value: $brightness, range: 0.2...1)
        } footer: {
          Text("A protective tint keeps the keys and suggestions readable over your photo.")
        }
      }
      .disabled(saving)
      .navigationTitle(draft.existing == nil ? "Photo Theme" : "Edit Photo")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            saveTask?.cancel()
            dismiss()
          }.disabled(saving)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(saving ? "Saving…" : draft.existing == nil ? "Use Photo" : "Save", action: save)
            .disabled(original == nil || saving || trimmedName.isEmpty)
            .accessibilityIdentifier("save-photo-theme")
        }
      }
      .interactiveDismissDisabled(saving)
      .alert(
        "Photo Theme Unavailable",
        isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
      ) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(error ?? "")
      }
      .task {
        do {
          original = try await Task.detached { try ThemePhotoCodec.image(draft.jpeg) }.value
        } catch {
          decodeFailed = true
          self.error =
            "This photo couldn’t be decoded. Cancel and choose another photo. Your current theme hasn’t changed."
        }
      }
      .task(id: PreviewRequest(crop: crop, brightness: brightness, ready: original != nil)) {
        guard let original else { return }
        do {
          try await Task.sleep(for: .milliseconds(120))
          let requestCrop = crop
          let requestBrightness = brightness
          let rendered = try await Task.detached {
            try ThemePhotoCodec.render(
              original, crop: requestCrop, brightness: requestBrightness, width: 640)
          }.value
          try Task.checkCancellation()
          preview = rendered
        } catch { /* Cancellation preserves the last complete preview. */  }
      }
    }
  }
  private struct PreviewRequest: Equatable {
    let crop: ThemePhotoCrop
    let brightness: Double
    let ready: Bool
  }
  private func control(_ title: String, value: Binding<Double>, range: ClosedRange<Double>)
    -> some View
  {
    VStack(alignment: .leading) {
      Text(title).font(.subheadline)
      Slider(value: value, in: range).accessibilityLabel(title)
    }
  }
  private func cropView(_ image: CGImage) -> some View {
    GeometryReader { geometry in
      let rect = crop.rectangle(imageWidth: Double(image.width), imageHeight: Double(image.height))
      let width = geometry.size.width
      let height = width / ThemePhotoCrop.aspectRatio
      Image(decorative: image, scale: 1).resizable()
        .frame(width: width / rect.width, height: height / rect.height)
        .offset(x: -rect.x * width / rect.width, y: -rect.y * height / rect.height)
        .frame(width: width, height: height, alignment: .topLeading)
        .overlay(.black.opacity(1 - brightness))
        .clipped().contentShape(Rectangle())
        .gesture(
          DragGesture().onChanged { value in
            let start = dragStart ?? crop
            if dragStart == nil { dragStart = start }
            crop.centerX = min(
              1, max(0, start.centerX - value.translation.width / width * rect.width))
            crop.centerY = min(
              1, max(0, start.centerY - value.translation.height / height * rect.height))
          }.onEnded { _ in
            normalizeCrop(image)
            dragStart = nil
          }
        )
        .simultaneousGesture(
          MagnifyGesture().onChanged { value in
            if zoomStart == nil { zoomStart = crop.zoom }
            crop.zoom = min(4, max(1, (zoomStart ?? 1) * value.magnification))
          }.onEnded { _ in
            normalizeCrop(image)
            zoomStart = nil
          }
        )
        .accessibilityLabel("Photo crop preview")
        .accessibilityHint("Use the framing sliders below to adjust the crop.")
    }
  }
  private func normalizeCrop(_ image: CGImage) {
    let rect = crop.rectangle(imageWidth: Double(image.width), imageHeight: Double(image.height))
    crop.centerX = rect.x + rect.width / 2
    crop.centerY = rect.y + rect.height / 2
  }
  private func save() {
    guard !saving, !trimmedName.isEmpty else { return }
    saving = true
    let record = KeyboardPhotoTheme(
      id: draft.existing?.id ?? UUID(), revision: UUID(), name: trimmedName, crop: crop,
      brightness: brightness)
    saveTask = Task {
      do {
        try await ThemePhotoLibrary.shared.save(record, source: draft.jpeg)
        saved(record)
        dismiss()
      } catch {
        saving = false
        if let failure = error as? KeyboardPhotoThemeStore.Failure {
          switch failure {
          case .unavailable:
            self.error =
              "Obadh couldn’t access its shared keyboard storage. Reopen Obadh and try again. Your current theme hasn’t changed."
          case .invalidMetadata:
            self.error =
              "The saved theme catalog couldn’t be read. No saved photos were overwritten, and your current theme hasn’t changed."
          case .invalidImage:
            self.error =
              "This photo couldn’t be prepared. Cancel and choose another photo. Your current theme hasn’t changed."
          case .storageFailure:
            self.error =
              "There wasn’t enough storage to save the photo theme. Your current theme hasn’t changed."
          }
        } else {
          self.error =
            "Your theme wasn’t changed. Check that there is free storage, then try again."
        }
      }
    }
  }
}
