import SwiftUI

struct ThemePhotoEditor: View {
  let draft: ThemePhotoDraft
  let saved: (KeyboardPhotoTheme) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var nameWasEdited = false
  @State private var isNaming = false
  @State private var isStyling = false
  @State private var styleModelAvailable = false
  @State private var styleTask: Task<Void, Never>?
  @State private var styleMessage: String?
  @State private var modelAvailable = false
  @State private var namingTask: Task<Void, Never>?
  @State private var crop: ThemePhotoCrop
  @State private var brightness: Double
  @State private var original: CGImage?
  @State private var dragStart: ThemePhotoCrop?
  @State private var zoomStart: Double?
  @State private var saving = false
  @State private var decodeFailed = false
  @State private var keyTransparency: Double
  @State private var keyOutlines: Bool
  @State private var keyBorderStrength: Double
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
    _name = State(initialValue: draft.existing?.name ?? "")
    _crop = State(initialValue: draft.existing?.crop ?? .init())
    _brightness = State(initialValue: draft.existing?.brightness ?? 0.65)
    _keyTransparency = State(initialValue: draft.existing?.keyTransparency ?? 0.25)
    _keyOutlines = State(initialValue: draft.existing?.keyOutlines ?? false)
    _keyBorderStrength = State(initialValue: draft.existing?.keyBorderStrength ?? 0.5)
  }
  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 14) {
          VStack(alignment: .leading, spacing: 5) {
            Text(showKeyboardPreview ? "Shape your keyboard"
              : draft.existing == nil ? "Frame your photo" : "Refine your photo")
              .font(.title2.bold())
            Text(showKeyboardPreview
              ? "Tune the keys over your photo before saving."
              : "Frame and name your photo, then customize the keyboard.")
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
                      keyOutlines: keyOutlines, keyTransparency: keyTransparency,
                      keyBorderStrength: keyBorderStrength), photo: original, editingCrop: crop,
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
            if !showKeyboardPreview {
              VStack(alignment: .leading, spacing: 10) {
                HStack {
                  Text("Name").font(.headline)
                  Spacer()
                  if styleModelAvailable {
                    Button("Suggest Name", systemImage: "sparkles") {
                      namingTask?.cancel()
                      namingTask = Task { await suggestName() }
                    }
                    .font(.footnote)
                    .disabled(isNaming || original == nil || saving)
                    .accessibilityIdentifier("suggest-photo-theme-name")
                  }
                }
                TextField("Theme Name", text: Binding(
                  get: { name },
                  set: { name = $0; nameWasEdited = true }
                ))
                  .textInputAutocapitalization(.words)
                  .focused($nameFocused)
                  .accessibilityIdentifier("photo-theme-name")
                  .padding(14)
                  .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                  .onChange(of: name) { _, value in
                    if value.count > 80 { name = String(value.prefix(80)) }
                  }
                if isNaming {
                  Label("Finding a name on this iPhone…", systemImage: "sparkles")
                    .font(.footnote).foregroundStyle(.secondary)
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
            if showKeyboardPreview {
              VStack(alignment: .leading, spacing: 12) {
                Text("Keys").font(.headline)
                VStack(alignment: .leading, spacing: 14) {
                  if modelAvailable {
                    HStack {
                      Button("Auto Style", systemImage: "sparkles") {
                        styleTask?.cancel()
                        styleTask = Task { await suggestKeyStyle() }
                      }
                      .disabled(isStyling || original == nil)
                      .accessibilityIdentifier("suggest-photo-key-style")
                      if isStyling { ProgressView().controlSize(.small) }
                    }
                  }
                  if let styleMessage {
                    Text(styleMessage).font(.footnote).foregroundStyle(.secondary)
                  }
                  VStack(alignment: .leading, spacing: 6) {
                    HStack {
                      Text("Transparency")
                      Spacer()
                      Text("\(Int((keyTransparency / 0.85 * 100).rounded()))%")
                        .foregroundStyle(.secondary).monospacedDigit()
                    }
                    Slider(value: $keyTransparency, in: 0...0.85)
                      .accessibilityLabel("Key Transparency")
                  }
                  Toggle("Key Borders", isOn: $keyOutlines)
                  if keyOutlines {
                    VStack(alignment: .leading, spacing: 6) {
                      Text("Border Definition")
                      Slider(value: $keyBorderStrength, in: 0...1)
                        .accessibilityLabel("Border Definition")
                    }
                  }
                  Text("Watch the glass respond over your photo as you adjust it.")
                    .font(.footnote).foregroundStyle(.secondary)
                }.padding(16).background(.regularMaterial,
                  in: RoundedRectangle(cornerRadius: 18))
              }
            }
          }
          .padding(.horizontal, 20).padding(.vertical, 12)
          .frame(maxWidth: 680).frame(maxWidth: .infinity)
        }
      }
      .background(Color(.systemGroupedBackground))
      .disabled(saving)
      .safeAreaInset(edge: .bottom, spacing: 0) {
        Button {
          if showKeyboardPreview {
            save()
          } else {
            nameFocused = false
            showKeyboardPreview = true
          }
        } label: {
          HStack(spacing: 8) {
            if saving { ProgressView().tint(.white) }
            Text(showKeyboardPreview
              ? saving ? "Saving…" : draft.existing == nil ? "Use Photo Theme" : "Save Changes"
              : "Next")
              .frame(maxWidth: .infinity)
          }.frame(minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .disabled(original == nil || saving || trimmedName.isEmpty)
        .accessibilityIdentifier(showKeyboardPreview ? "save-photo-theme" : "next-photo-theme")
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
      .onDisappear {
        namingTask?.cancel()
        styleTask?.cancel()
      }
      .alert(
        "Photo Theme Unavailable",
        isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
      ) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(error ?? "")
      }
      .task {
        let fallback = await ThemePhotoLibrary.shared.nextAvailableName()
        if draft.existing == nil, name.isEmpty { name = fallback }
        let isGenerated = await ThemePhotoLibrary.shared.isGeneratedName(name)
        let modelAvailable = await ThemePhotoLibrary.shared.canSuggestName()
        self.modelAvailable = modelAvailable
        styleModelAvailable = await ThemePhotoLibrary.shared.canSuggestKeyStyle()
        do {
          original = try await Task.detached { try ThemePhotoCodec.image(draft.jpeg) }.value
        } catch {
          decodeFailed = true
          self.error =
            "This photo couldn’t be decoded. Cancel and choose another photo. Your current theme hasn’t changed."
          return
        }
        if (draft.existing == nil || isGenerated) && modelAvailable && !nameWasEdited {
          await suggestName(automatic: true)
        }
      }
    }
  }
  private func suggestName(automatic: Bool = false) async {
    guard !isNaming, !saving, original != nil else { return }
    let startingName = name
    let startingCrop = crop
    isNaming = true
    defer { isNaming = false }
    guard let suggestion = await ThemePhotoLibrary.shared.suggestedName(
      for: draft.jpeg, crop: startingCrop, excluding: draft.existing?.id),
      !Task.isCancelled, !saving, name == startingName,
      (!automatic || !nameWasEdited)
    else { return }
    name = suggestion
  }
  private func suggestKeyStyle() async {
    guard !isStyling, !saving, original != nil, styleModelAvailable else { return }
    let startingCrop = crop
    let startingTransparency = keyTransparency
    let startingOutlines = keyOutlines
    let startingBorderStrength = keyBorderStrength
    isStyling = true
    styleMessage = nil
    defer { isStyling = false }
    guard let suggestion = await ThemePhotoLibrary.shared.suggestedKeyStyle(
      for: draft.jpeg, crop: startingCrop) else {
      if !Task.isCancelled { styleMessage = "Couldn’t analyze this photo. Your settings are unchanged." }
      return
    }
    guard !Task.isCancelled, !saving, crop == startingCrop,
      keyTransparency == startingTransparency, keyOutlines == startingOutlines,
      keyBorderStrength == startingBorderStrength else { return }
    keyTransparency = suggestion.transparency
    keyOutlines = suggestion.outlines
    keyBorderStrength = suggestion.borderStrength
    styleMessage = "Suggested from your photo. Fine-tune anything you like."
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
      brightness: brightness, keyTransparency: keyTransparency,
      keyOutlines: keyOutlines, keyBorderStrength: keyBorderStrength)
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
