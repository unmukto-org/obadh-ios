import SwiftUI

struct ThemePhotoEditor: View {
  let draft: ThemePhotoDraft
  let saved: (KeyboardPhotoTheme) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var crop: ThemePhotoCrop
  @State private var brightness: Double
  @State private var original: CGImage?
  @State private var dragStart: ThemePhotoCrop?
  @State private var zoomStart: Double?
  @State private var saving = false
  @State private var decodeFailed = false
  private let outlines = KeyboardPreferences().appearance.keyOutlines
  @State private var error: String?
  @State private var saveTask: Task<Void, Never>?
  @State private var showKeyboardPreview = false
  @State private var previewWidth: CGFloat = 414
  @FocusState private var nameFocused: Bool
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
      VStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 14) {
          VStack(alignment: .leading, spacing: 5) {
            Text(draft.existing == nil ? "Frame your photo" : "Refine your photo")
              .font(.title2.bold())
            Text("See each adjustment on the keyboard as you work.")
              .font(.subheadline).foregroundStyle(.secondary)
          }
          if !nameFocused {
            VStack(alignment: .leading, spacing: 12) {
              Picker("Preview", selection: $showKeyboardPreview) {
                Text("Photo").tag(false)
                Text("Keyboard").tag(true)
              }.pickerStyle(.segmented)
              GeometryReader { geometry in
                Group {
                  if showKeyboardPreview {
                    ThemePreview(appearance: .init(
                      themeID: "photo." + (draft.existing?.id ?? draft.id).uuidString,
                      keyOutlines: outlines), photo: original, editingCrop: crop,
                      editingBrightness: brightness)
                  } else if let original {
                    cropView(original)
                  } else if decodeFailed {
                    ContentUnavailableView("Photo unavailable",
                      systemImage: "photo.badge.exclamationmark",
                      description: Text("Choose another photo to create a theme."))
                  } else {
                    ProgressView("Preparing Photo…")
                  }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .onAppear { previewWidth = geometry.size.width }
                .onChange(of: geometry.size.width) { _, width in previewWidth = width }
              }
              .frame(height: previewWidth * 280.0 / 414.0)
              .clipShape(RoundedRectangle(cornerRadius: 18))
              .overlay(RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color(.separator).opacity(0.18)))
              HStack(spacing: 12) {
                Text(showKeyboardPreview
                  ? "Live preview · Photo stays on device"
                  : "Drag to move · Pinch to zoom")
                  .font(.footnote).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if !showKeyboardPreview, let original {
                  frameOptions(for: original)
                  if crop != .init() {
                    Button("Reset") { crop = .init() }
                      .font(.footnote)
                      .accessibilityIdentifier("reset-photo-crop")
                  }
                }
              }
            }
          }
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 16)
        .frame(maxWidth: 680).frame(maxWidth: .infinity)
        Divider()
        ScrollView {
          VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
              Text("Name").font(.headline)
              TextField("Theme Name", text: $name)
                .textInputAutocapitalization(.words)
                .focused($nameFocused)
                .accessibilityIdentifier("photo-theme-name")
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .onChange(of: name) { _, value in
                  if value.count > 80 { name = String(value.prefix(80)) }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
              Text("Readability").font(.headline)
              VStack(alignment: .leading, spacing: 12) {
                control("Photo Brightness", value: $brightness, range: 0.2...1)
                Text("A subtle tint keeps the keys and suggestions easy to read.")
                  .font(.footnote).foregroundStyle(.secondary)
              }.padding(16).background(.regularMaterial,
                in: RoundedRectangle(cornerRadius: 18))
            }
          }
          .padding(.horizontal, 20).padding(.vertical, 12)
          .frame(maxWidth: 680).frame(maxWidth: .infinity)
        }
      }
      .background(Color(.systemGroupedBackground))
      .disabled(saving)
      .safeAreaInset(edge: .bottom, spacing: 0) {
        Button(action: save) {
          HStack(spacing: 8) {
            if saving { ProgressView().tint(.white) }
            Text(saving ? "Saving…" : draft.existing == nil ? "Use Photo Theme" : "Save Changes")
              .frame(maxWidth: .infinity)
          }.frame(minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .disabled(original == nil || saving || trimmedName.isEmpty)
        .accessibilityIdentifier("save-photo-theme")
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(.bar)
      }
      .navigationTitle(draft.existing == nil ? "Photo Theme" : "Edit Photo Theme")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            saveTask?.cancel()
            dismiss()
          }.disabled(saving)
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
    }
  }
  private func control(_ title: String, value: Binding<Double>, range: ClosedRange<Double>)
    -> some View
  {
    VStack(alignment: .leading) {
      Text(title).font(.subheadline)
      Slider(value: value, in: range).accessibilityLabel(title)
    }
  }
  private func frameOptions(for image: CGImage) -> some View {
    let rect = crop.rectangle(imageWidth: Double(image.width), imageHeight: Double(image.height))
    return Menu {
      Section("Zoom") {
        Button("Zoom In", systemImage: "plus.magnifyingglass") { adjustZoom(1.25, image) }
          .disabled(crop.zoom >= 4)
        Button("Zoom Out", systemImage: "minus.magnifyingglass") { adjustZoom(0.8, image) }
          .disabled(crop.zoom <= 1)
      }
      Section("Position") {
        Button("Move Picture Left", systemImage: "arrow.left") {
          movePicture(x: 1, y: 0, image)
        }.disabled(rect.x + rect.width >= 1 - 0.000_001)
        Button("Move Picture Right", systemImage: "arrow.right") {
          movePicture(x: -1, y: 0, image)
        }.disabled(rect.x <= 0.000_001)
        Button("Move Picture Up", systemImage: "arrow.up") {
          movePicture(x: 0, y: 1, image)
        }.disabled(rect.y + rect.height >= 1 - 0.000_001)
        Button("Move Picture Down", systemImage: "arrow.down") {
          movePicture(x: 0, y: -1, image)
        }.disabled(rect.y <= 0.000_001)
      }
    } label: {
      Image(systemName: "ellipsis.circle")
        .font(.title3)
        .frame(minWidth: 32, minHeight: 32)
        .contentShape(Rectangle())
    }
    .accessibilityLabel("Frame options")
    .accessibilityHint("Adjust the photo without gestures")
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Photo crop preview")
        .accessibilityHint("Drag to move or pinch to zoom. Frame options offers buttons for each adjustment.")
        .accessibilityIdentifier("photo-crop-preview")
        .accessibilityAction(named: Text("Zoom In")) { adjustZoom(1.25, image) }
        .accessibilityAction(named: Text("Zoom Out")) { adjustZoom(0.8, image) }
        .accessibilityAction(named: Text("Move Picture Left")) {
          movePicture(x: 1, y: 0, image)
        }
        .accessibilityAction(named: Text("Move Picture Right")) {
          movePicture(x: -1, y: 0, image)
        }
        .accessibilityAction(named: Text("Move Picture Up")) {
          movePicture(x: 0, y: 1, image)
        }
        .accessibilityAction(named: Text("Move Picture Down")) {
          movePicture(x: 0, y: -1, image)
        }
    }
  }
  private func adjustZoom(_ factor: Double, _ image: CGImage) {
    crop.zoom = min(4, max(1, crop.zoom * factor))
    normalizeCrop(image)
  }
  private func movePicture(x: Double, y: Double, _ image: CGImage) {
    let rect = crop.rectangle(imageWidth: Double(image.width), imageHeight: Double(image.height))
    crop.centerX += x * rect.width * 0.1
    crop.centerY += y * rect.height * 0.1
    normalizeCrop(image)
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
