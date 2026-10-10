import SwiftUI

struct ThemePreview: UIViewRepresentable {
  let appearance: KeyboardAppearance
  var photo: CGImage? = nil
  var editingCrop: ThemePhotoCrop? = nil
  var editingBrightness: Double = 1
  func makeUIView(context: Context) -> KeyboardThemePreviewView { KeyboardThemePreviewView() }
  func updateUIView(_ view: KeyboardThemePreviewView, context: Context) {
    view.display(appearance, photo: photo, editingCrop: editingCrop,
      editingBrightness: editingBrightness)
  }
}

struct ThemeSelection: Identifiable {
  let id: String
  var photo: KeyboardPhotoTheme? = nil
  var name: String { photo?.name ?? KeyboardThemeCatalog.preset(id)?.name ?? "System" }
}

struct ThemePhotoDraft: Identifiable {
  let id = UUID()
  let jpeg: Data
  let existing: KeyboardPhotoTheme?
}

struct ThemeDetailView: View {
  let selection: ThemeSelection
  let appearance: KeyboardAppearance
  let apply: (KeyboardAppearance) -> Void
  let edit: () -> Void
  let delete: () -> Void
  @Binding var error: String?
  @Environment(\.dismiss) private var dismiss
  @State private var mode: KeyboardAppearance.Mode
  @State private var outlines: Bool
  @State private var image: CGImage?
  @State private var deleteConfirmation = false
  @State private var photoLoadFailed = false

  init(
    selection: ThemeSelection, appearance: KeyboardAppearance,
    apply: @escaping (KeyboardAppearance) -> Void, edit: @escaping () -> Void,
    delete: @escaping () -> Void, error: Binding<String?>
  ) {
    self.selection = selection
    self.appearance = appearance
    self.apply = apply
    self.edit = edit
    self.delete = delete
    self._error = error
    _mode = State(initialValue: appearance.mode)
    _outlines = State(initialValue: appearance.keyOutlines)
  }
  private var proposed: KeyboardAppearance {
    .init(themeID: selection.id, mode: mode, keyOutlines: outlines)
  }
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          Text(selection.name).font(.title2.bold())
          ThemePreview(appearance: proposed, photo: image)
            .aspectRatio(414.0 / 280.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18)
              .strokeBorder(Color(.separator).opacity(0.18)))
            .accessibilityLabel("Keyboard preview")
          if photoLoadFailed {
            Text(
              "This saved photo couldn’t be loaded. Edit it to rebuild the theme, or choose another theme."
            ).font(.footnote).foregroundStyle(.secondary)
          }
          if selection.id == "system" {
            VStack(alignment: .leading, spacing: 10) {
              Text("Appearance").font(.headline)
            Picker("Appearance", selection: $mode) {
              Text("Automatic").tag(KeyboardAppearance.Mode.automatic)
              Text("Light").tag(KeyboardAppearance.Mode.light)
              Text("Dark").tag(KeyboardAppearance.Mode.dark)
              }.pickerStyle(.segmented)
              Text("Automatic follows the appearance requested by the app you’re typing in.")
                .font(.footnote).foregroundStyle(.secondary)
            }
          }
          Toggle("Key Outlines", isOn: $outlines)
            .padding(16).background(.regularMaterial,
              in: RoundedRectangle(cornerRadius: 18))
          if selection.photo != nil {
            VStack(spacing: 0) {
              Button(action: edit) {
                Label("Edit Photo", systemImage: "slider.horizontal.3")
                  .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
              }
              Divider()
              Button(role: .destructive) { deleteConfirmation = true } label: {
                Label("Delete Theme", systemImage: "trash")
                  .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
              }
            }
            .padding(.horizontal, 16).background(.regularMaterial,
              in: RoundedRectangle(cornerRadius: 18))
          }
        }
        .padding(.horizontal, 20).padding(.vertical, 22)
        .frame(maxWidth: 680).frame(maxWidth: .infinity)
      }
      .background(Color(.systemGroupedBackground))
      .safeAreaInset(edge: .bottom, spacing: 0) {
        Button {
          apply(proposed)
          dismiss()
        } label: {
          Text("Use Theme").frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("use-theme")
        .disabled(selection.photo != nil && image == nil)
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(.bar)
      }
      .navigationTitle("Preview")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      }
      .alert(
        "Photo Theme Unavailable",
        isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
      ) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(error ?? "")
      }
      .confirmationDialog(
        "Delete this photo theme?", isPresented: $deleteConfirmation, titleVisibility: .visible
      ) {
        Button("Delete Theme", role: .destructive, action: delete)
      } message: {
        Text("The original photo in your library will stay untouched.")
      }
      .task(id: selection.id) {
        guard let photo = selection.photo, let url = KeyboardPhotoThemeStore().renderURL(photo)
        else { return }
        let decoded = await Task.detached { KeyboardThemeImage.decode(url) }.value
        if !Task.isCancelled {
          image = decoded
          photoLoadFailed = decoded == nil
        }
      }
    }
  }
}
