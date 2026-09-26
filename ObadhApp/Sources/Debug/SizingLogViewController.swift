#if DEBUG
import UIKit

/// DEBUG-only reader for KeyboardSizingLog: shows what the keyboard extension
/// recorded about each presentation and shares the raw file, so a device repro
/// session produces evidence that can leave the phone.
///
/// The one quantity missing here is the system's container band, which the
/// extension cannot observe. That comes from a probe screenshot; the `#id` shown
/// on the probe overlay matches the `#id` in this list.
final class SizingLogViewController: UIViewController {
    private let textView = UITextView()
    private let log = KeyboardSizingLog.shared

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Sizing Log"
        view.backgroundColor = .systemBackground
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.alwaysBounceVertical = true
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(share)),
            UIBarButtonItem(barButtonSystemItem: .refresh, target: self, action: #selector(reload)),
            UIBarButtonItem(barButtonSystemItem: .trash, target: self, action: #selector(clear))
        ]
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    @objc private func reload() {
        let entries = log.entries()
        // Mirror on every read so the file is pullable over USB from the app's
        // own container without going through the share sheet.
        log.mirrorToAppDocuments()
        guard !entries.isEmpty else {
            textView.text = """
                No presentations recorded yet.

                1. Turn on the probe overlay (Diagnostics).
                2. Open a host app so the keyboard appears.
                3. Come back here and pull to refresh.
                """
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        var lines = ["\(entries.count) presentations, newest first", ""]
        for entry in entries {
            let late = entry.lateHeights.isEmpty
                ? ""
                : "  LATE " + entry.lateHeights.map { String(Int($0)) }.joined(separator: "›")
            let actualStrip = entry.actualStrip.map { String(format: "%.1f", $0) } ?? "unknown"
            lines.append(
                """
                #\(entry.id)  \(formatter.string(from: entry.date))  n\(entry.presentation) \
                pid\(entry.pid) up\(String(format: "%.2f", entry.uptime))s
                   trace \(entry.trace.joined(separator: "›"))\(late)
                   ask \(Int(entry.ask))  strip \(Int(entry.strip))  settled \(Int(entry.settled))  \
                \(entry.presentationClass) (\(entry.mode))  \(entry.dark ? "dark" : "light")  \
                iOS \(entry.systemVersion)  \(entry.screen)
                   actual ribbon \(actualStrip)
                """
            )
        }
        textView.text = lines.joined(separator: "\n")
    }

    @objc private func share(_ sender: UIBarButtonItem) {
        guard let url = log.mirrorToAppDocuments() else { return }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.popoverPresentationController?.barButtonItem = sender
        present(controller, animated: true)
    }

    @objc private func clear() {
        log.clear()
        reload()
    }
}
#endif
