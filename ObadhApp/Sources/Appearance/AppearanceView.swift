import PhotosUI
import SwiftUI

struct AppearanceView: View {
  private let preferences = KeyboardPreferences()
  @State private var appearance = KeyboardPreferences().appearance
  @State private var photos: [KeyboardPhotoTheme] = []
  @State private var selection: ThemeSelection?
  @State private var draft: ThemePhotoDraft?
  @State private var pendingDraft: ThemePhotoDraft?
  @State private var pickerItem: PhotosPickerItem?
  @State private var importing = false
  @State private var importProgress: Progress?
  @State private var importGeneration = UUID()
  @State private var error: String?
  @State private var collection: ThemeCollection = .colors
  @State private var searchText = ""
  private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 14)]
  private var visiblePresets: [KeyboardThemePreset] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    if query.isEmpty {
      let presets = KeyboardThemeCatalog.presets.filter { $0.group == collection.group }
      let spotlight = collection.spotlightIDs
      return spotlight.compactMap(KeyboardThemeCatalog.preset)
        + presets.filter { !spotlight.contains($0.id) }
    }
    return KeyboardThemeCatalog.presets.filter {
      $0.name.localizedStandardContains(query)
        || $0.id.replacingOccurrences(of: "_", with: " ").localizedStandardContains(query)
        || $0.group.localizedStandardContains(query)
    }
  }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        Button {
          selection = ThemeSelection(id: "system")
        } label: {
          HStack(spacing: 14) {
            Image(systemName: "keyboard").font(.title2).frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
              Text("System").font(.headline)
              Text("The original Obadh keyboard").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if appearance.isSystem {
              Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
            } else {
              Image(systemName: "chevron.forward").foregroundStyle(.tertiary)
            }
          }.padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(
              appearance.isSystem ? Color.accentColor : Color(.separator).opacity(0.16),
              lineWidth: appearance.isSystem ? 2 : 1))
        }.buttonStyle(.plain).accessibilityIdentifier("theme-system")
          .accessibilityAddTraits(appearance.isSystem ? .isSelected : [])
        VStack(alignment: .leading, spacing: 12) {
          PhotosPicker(selection: $pickerItem, matching: .images, preferredItemEncoding: .current) {
            HStack(spacing: 14) {
              Image(systemName: "photo.badge.plus").font(.title2)
                .frame(width: 44, height: 44)
              VStack(alignment: .leading, spacing: 3) {
                Text("Create from a Photo").font(.headline)
                Text("Your photo, your keyboard")
                  .font(.subheadline).foregroundStyle(.secondary)
              }
              Spacer()
              Image(systemName: "chevron.forward").foregroundStyle(.tertiary)
            }
            .padding(16).background(.regularMaterial,
              in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20)
              .strokeBorder(Color(.separator).opacity(0.16)))
          }.buttonStyle(.plain).accessibilityIdentifier("add-photo-theme")
            .disabled(importing)
          if importing {
            HStack {
              ProgressView("Loading Photo…")
              Spacer()
              Button("Cancel") { cancelImport() }
            }
          }
          if !photos.isEmpty {
            Text("Your Photos").font(.headline)
            LazyVGrid(columns: columns, spacing: 16) {
              ForEach(photos) { photo in
                PhotoThemeCard(photo: photo, appearance: appearance,
                  selected: appearance.themeID == photo.themeID) {
                  selection = ThemeSelection(id: photo.themeID, photo: photo)
                }
              }
            }
          }
        }
        VStack(alignment: .leading, spacing: 16) {
          Text(searchText.isEmpty ? "Collections" : "Search Results").font(.title2.bold())
          if searchText.isEmpty {
            Picker("Collection", selection: $collection) {
              ForEach(ThemeCollection.allCases) { item in
                Text(item.title).tag(item)
              }
            }.pickerStyle(.segmented).accessibilityIdentifier("theme-collection")
          }
          LazyVGrid(columns: columns, spacing: 14) {
            ForEach(visiblePresets) { preset in
              Button {
                selection = ThemeSelection(id: preset.id)
              } label: {
                ThemeCard(name: preset.name, selected: appearance.themeID == preset.id) {
                  ThemeThumbnail(appearance: .init(
                    themeID: preset.id, mode: appearance.mode,
                    keyOutlines: appearance.keyOutlines,
                    keyTransparency: appearance.keyTransparency,
                    keyBorderStrength: appearance.keyBorderStrength))
                }
              }.buttonStyle(.plain).accessibilityIdentifier("theme-" + preset.id)
                .accessibilityAddTraits(appearance.themeID == preset.id ? .isSelected : [])
            }
          }
          if visiblePresets.isEmpty {
            ContentUnavailableView.search(text: searchText)
          }
        }
      }.padding(.horizontal, 20).padding(.vertical, 14)
        .frame(maxWidth: 680).frame(maxWidth: .infinity)
    }
    .background(Color(.systemGroupedBackground))
    .navigationTitle("Themes").navigationBarTitleDisplayMode(.large)
    .searchable(text: $searchText, prompt: "Search Themes")
    .sheet(
      item: $selection,
      onDismiss: {
        if let next = pendingDraft {
          pendingDraft = nil
          draft = next
        }
      }
    ) { theme in
      ThemeDetailView(
        selection: theme, appearance: appearance, apply: apply,
        edit: { edit(theme) }, delete: { remove(theme) }, error: $error)
    }
    .sheet(item: $draft, onDismiss: { Task { await reloadPhotos() } }) { draft in
      ThemePhotoEditor(draft: draft) { record in
        if draft.existing == nil || appearance.photoID == record.id {
          var next = appearance
          next.themeID = record.themeID
          next.keyTransparency = record.keyTransparency
          next.keyOutlines = record.keyOutlines
          next.keyBorderStrength = record.keyBorderStrength
          apply(next)
        }
      }
    }
    .alert(
      "Photo Theme Unavailable",
      isPresented: Binding(
        get: { error != nil && selection == nil && draft == nil }, set: { if !$0 { error = nil } })
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(error ?? "")
    }
    .task {
      await ThemePhotoLibrary.shared.migrateLegacyNames()
      await reloadPhotos()
      await ThemePhotoLibrary.shared.collect()
      if let group = KeyboardThemeCatalog.preset(appearance.themeID)?.group,
        let selected = ThemeCollection.allCases.first(where: { $0.group == group }) {
        collection = selected
      }
      if await ThemePhotoLibrary.shared.canSuggestName() {
        for photo in photos {
          guard !Task.isCancelled else { break }
          if await ThemePhotoLibrary.shared.renameGeneratedPhoto(photo) {
            await reloadPhotos()
          }
        }
      }
    }
    .onChange(of: pickerItem) { _, item in if let item { importPhoto(item) } }
    .onDisappear { cancelImport() }
  }
  private func apply(_ next: KeyboardAppearance) {
    preferences.appearance = next
    appearance = preferences.appearance
  }
  private func reloadPhotos() async { photos = await ThemePhotoLibrary.shared.photos() }
  private func cancelImport() {
    importProgress?.cancel()
    importProgress = nil
    importGeneration = UUID()
    importing = false
    pickerItem = nil
  }
  private func importPhoto(_ item: PhotosPickerItem) {
    cancelImport()
    importing = true
    let generation = UUID()
    importGeneration = generation
    importProgress = item.loadTransferable(type: ThemePhotoImport.self) { result in
      Task { @MainActor in
        guard importGeneration == generation else { return }
        importProgress = nil
        importing = false
        switch result {
        case .success(let imported):
          if let imported {
            draft = ThemePhotoDraft(jpeg: imported.jpeg, existing: nil)
          } else {
            self.error =
              "This photo couldn’t be decoded. Choose another photo. Your current theme hasn’t changed."
          }
        case .failure:
          self.error =
            "The selected photo couldn’t be loaded. If it is stored in iCloud, check your connection and choose it again. You can also try another photo. Your current theme hasn’t changed."
        }
      }
    }
  }

  private func edit(_ theme: ThemeSelection) {
    guard let photo = theme.photo else { return }
    Task {
      do {
        let data = try await ThemePhotoLibrary.shared.source(photo)
        guard selection?.id == theme.id else { return }
        pendingDraft = ThemePhotoDraft(jpeg: data, existing: photo)
        selection = nil
      } catch {
        self.error = "The saved photo couldn’t be opened. Your current theme hasn’t changed."
      }
    }
  }
  private func remove(_ theme: ThemeSelection) {
    guard let photo = theme.photo else { return }
    Task {
      do {
        try await ThemePhotoLibrary.shared.remove(photo)
        if appearance.photoID == photo.id {
          var next = appearance
          next.themeID = "system"
          apply(next)
        }
        selection = nil
        await reloadPhotos()
      } catch {
        self.error = "The photo theme couldn’t be deleted. Your current theme hasn’t changed."
      }
    }
  }
}

private enum ThemeCollection: String, CaseIterable, Identifiable {
  case colors, light, dark
  var id: Self { self }
  var title: String {
    switch self {
    case .colors: "Colors"
    case .light: "Daylight"
    case .dark: "After Dark"
    }
  }
  var group: String {
    switch self {
    case .colors: "Colors"
    case .light: "Light gradient"
    case .dark: "Dark gradient"
    }
  }
  /// Lead with the palettes that show each collection's range at a glance;
  /// persistent IDs and the shared catalog order are unchanged.
  var spotlightIDs: [String] {
    switch self {
    case .colors: ["light_pink", "blue", "teal", "sand", "deep_purple", "cyan"]
    case .light: ["light_gradient_7", "light_gradient_8", "light_gradient_24",
      "light_gradient_6", "light_gradient_14", "light_gradient_11"]
    case .dark: ["dark_gradient_1", "dark_gradient_28", "dark_gradient_24",
      "dark_gradient_21", "dark_gradient_25", "dark_gradient_16"]
    }
  }
}

private struct ThemeCard<Artwork: View>: View {
  let name: String
  let selected: Bool
  var artworkAspectRatio: CGFloat = 414.0 / 280.0
  @ViewBuilder let artwork: () -> Artwork
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      artwork().aspectRatio(artworkAspectRatio, contentMode: .fit)
        .overlay(alignment: .topTrailing) {
          if selected {
            Image(systemName: "checkmark.circle.fill")
              .symbolRenderingMode(.palette)
              .foregroundStyle(.white, Color.accentColor)
              .font(.title3).padding(10)
          }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
      Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
        .lineLimit(2).frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .padding(.horizontal, 12)
    }
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17))
    .clipShape(RoundedRectangle(cornerRadius: 17))
    .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(
      selected ? Color.accentColor : Color(.separator).opacity(0.12),
      lineWidth: selected ? 2 : 1))
    .contentShape(RoundedRectangle(cornerRadius: 17))
    .accessibilityElement(children: .ignore).accessibilityLabel(name)
    .accessibilityHint("Preview this keyboard theme")
  }
}

private struct PhotoThemeCard: View {
  let photo: KeyboardPhotoTheme
  let appearance: KeyboardAppearance
  let selected: Bool
  let action: () -> Void
  @State private var image: CGImage?
  @State private var decodedRevision: UUID?
  var body: some View {
    Button(action: action) {
      ThemeCard(
        name: photo.name, selected: selected, artworkAspectRatio: ThemeThumbnail.aspectRatio
      ) {
        ThemeThumbnail(appearance: .init(themeID: photo.themeID, mode: appearance.mode,
          keyOutlines: photo.keyOutlines, keyTransparency: photo.keyTransparency,
          keyBorderStrength: photo.keyBorderStrength, revision: photo.revision),
          photo: decodedRevision == photo.revision ? image : nil)
      }
    }.buttonStyle(.plain).accessibilityIdentifier("theme-" + photo.themeID)
      .accessibilityAddTraits(selected ? .isSelected : [])
      .task(id: photo.revision) {
        guard let url = KeyboardPhotoThemeStore().thumbnailURL(photo) else { return }
        let decoded = await Task.detached { KeyboardThemeImage.decode(url, maxSide: 240) }.value
        if !Task.isCancelled {
          image = decoded
          decodedRevision = photo.revision
        }
      }
  }
}
