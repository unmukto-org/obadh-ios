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
  private let columns = [GridItem(.adaptive(minimum: 145, maximum: 220), spacing: 16)]
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
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
          }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 20))
        }.buttonStyle(.plain).accessibilityIdentifier("theme-system")
          .accessibilityAddTraits(appearance.isSystem ? .isSelected : [])
        VStack(alignment: .leading, spacing: 12) {
          Text("My Photos").font(.title3.bold())
          PhotosPicker(selection: $pickerItem, matching: .images, preferredItemEncoding: .current) {
            Label("Add Photo Theme", systemImage: "photo.badge.plus").frame(
              maxWidth: .infinity, minHeight: 44)
          }.buttonStyle(.bordered).accessibilityIdentifier("add-photo-theme").disabled(importing)
          if importing {
            HStack {
              ProgressView("Loading Photo…")
              Spacer()
              Button("Cancel") { cancelImport() }
            }
          }
          if !photos.isEmpty {
            LazyVGrid(columns: columns, spacing: 16) {
              ForEach(photos) { photo in
                PhotoThemeCard(photo: photo, appearance: appearance,
                  selected: appearance.themeID == photo.themeID) {
                  selection = ThemeSelection(id: photo.themeID, photo: photo)
                }
              }
            }
          }
          Text(
            "Only the photo you select is shared with Obadh. It’s used locally for your keyboard."
          )
          .font(.footnote).foregroundStyle(.secondary)
        }
        ForEach(KeyboardThemeCatalog.groups, id: \.self) { group in
          VStack(alignment: .leading, spacing: 12) {
            Text(
              group == "Light gradient"
                ? "Light Gradients" : group == "Dark gradient" ? "Dark Gradients" : group
            ).font(.title3.bold())
            LazyVGrid(columns: columns, spacing: 16) {
              ForEach(KeyboardThemeCatalog.presets.filter { $0.group == group }) { preset in
                Button {
                  selection = ThemeSelection(id: preset.id)
                } label: {
                  ThemeCard(name: preset.name, selected: appearance.themeID == preset.id) {
                    ThemeThumbnail(appearance: .init(
                      themeID: preset.id, mode: appearance.mode,
                      keyOutlines: appearance.keyOutlines))
                  }
                }.buttonStyle(.plain).accessibilityIdentifier("theme-" + preset.id)
                  .accessibilityAddTraits(appearance.themeID == preset.id ? .isSelected : [])
              }
            }
          }
        }
      }.padding(20).frame(maxWidth: 680).frame(maxWidth: .infinity)
    }
    .background(Color(.systemGroupedBackground))
    .navigationTitle("Appearance").navigationBarTitleDisplayMode(.inline)
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
      await reloadPhotos()
      await ThemePhotoLibrary.shared.collect()
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

private struct ThemeCard<Artwork: View>: View {
  let name: String
  let selected: Bool
  @ViewBuilder let artwork: () -> Artwork
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      artwork().aspectRatio(414.0 / 280.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .allowsHitTesting(false).accessibilityHidden(true)
      HStack(alignment: .firstTextBaseline) {
        Text(name).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
          .multilineTextAlignment(.leading)
        Spacer(minLength: 4)
        if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
      }
    }.contentShape(Rectangle())
      .accessibilityElement(children: .ignore).accessibilityLabel(name)
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
      ThemeCard(name: photo.name, selected: selected) {
        ThemeThumbnail(appearance: .init(themeID: photo.themeID, mode: appearance.mode,
          keyOutlines: appearance.keyOutlines, revision: photo.revision),
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
