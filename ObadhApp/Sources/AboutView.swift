import SwiftUI
import UIKit

/// Identity and build provenance. The stamp lives here rather than under a section
/// footer on the main screen: it matters — a keyboard extension will happily serve a
/// cached old binary, and this is how you tell what is actually installed — but it is
/// something you go looking for, not something you read every day.
struct AboutView: View {
    @Environment(\.colorScheme) private var scheme
    @State private var didCopy = false

    var body: some View {
        List {
            Section {
                header
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section {
                LabeledContent("Version", value: AppBuildInfo.shortVersion)
                LabeledContent("Engine Version", value: AppBuildInfo.engineVersion)
                LabeledContent("Build", value: AppBuildInfo.buildNumber)
                LabeledContent("Commit") { monospaced(revision) }
                LabeledContent("Built") { monospaced(builtAt) }
            }

            Section {
                Button {
                    UIPasteboard.general.string = AppBuildInfo.summary
                    withAnimation { didCopy = true }
                } label: {
                    Label(
                        didCopy ? "Copied" : "Copy Build Details",
                        systemImage: didCopy ? "checkmark" : "doc.on.doc"
                    )
                }
                .disabled(didCopy)
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image("BrandIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 84 * 0.2237, style: .continuous))
                .shadow(color: .black.opacity(0.22), radius: 10, y: 5)

            Text("Obadh")
                .font(BrandFont.wordmark(30))
                .foregroundStyle(BrandGradient.wordmark(scheme))

            Text("ভাষা হোক আরও উন্মুক্ত")
                .font(BrandFont.bangla(15))
                .foregroundStyle(.secondary)
        }
    }

    private func monospaced(_ text: String) -> some View {
        Text(text)
            .font(.body.monospaced())
            .foregroundStyle(.secondary)
    }

    private var revision: String {
        AppBuildInfo.gitRevision.isEmpty ? "—" : AppBuildInfo.gitRevision
    }

    /// `stamp-build.sh` writes UTC as `2026-07-10.0529`.
    private var builtAt: String {
        let raw = AppBuildInfo.buildTime
        let parts = raw.split(separator: ".")
        guard parts.count == 2, parts[1].count == 4 else { return raw.isEmpty ? "—" : raw }
        let time = parts[1]
        return "\(parts[0]) \(time.prefix(2)):\(time.suffix(2)) UTC"
    }
}
