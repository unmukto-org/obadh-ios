import SwiftUI
import UIKit

/// The voice screen the keyboard's mic opens. It is already listening when it
/// appears; the words show here as they are recognized; Done (or a pause) releases
/// the microphone, and ◀ Back hands the text to the keyboard. Standard sheet
/// anatomy (Cancel and Done up top), large text, and the voice light below.
/// Once finished, guidance sits directly below the system's back-to-app control.
struct VoiceSessionScreen: View {
    @ObservedObject var session: VoiceSessionController
    @ObservedObject var models: VoiceModelLibrary
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            if let failure = session.failure {
                VoiceFailureView(failure: failure, models: models)
            } else {
                VoiceTranscriptView(transcript: session.transcript, isFinal: session.hasFinalText)
                    .accessibilityIdentifier("voice.transcript")
                    .padding(.bottom, session.hasFinalText ? 24 : 0)
                footer
            }
        }
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    // MARK: Header: Cancel · Done, like any system sheet

    @ViewBuilder private var header: some View {
        if session.hasFinalText {
            HStack(alignment: .top, spacing: 16) {
                ReturnHint()
                    .accessibilityIdentifier("voice.returnHint")
                    .frame(maxWidth: .infinity, alignment: .leading)
                cancelButton
                    .padding(.top, 4)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 16)
        } else {
            HStack {
                cancelButton
                Spacer()
                if session.phase == .listening {
                    Button("Done") { session.finishDictation() }
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("voice.done")
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 52)
        }
    }

    private var cancelButton: some View {
        Button("Cancel") {
            session.cancelDictation()
            onClose()
        }
        .accessibilityIdentifier("voice.cancel")
    }

    // MARK: Footer: the light while listening

    @ViewBuilder private var footer: some View {
        if !session.hasFinalText {
            VoiceLens(feed: session.levels, mode: lensMode)
                .frame(height: 64)
                .padding(.bottom, 24)
                .transition(.opacity)
                .accessibilityHidden(true)
        }
    }

    private var lensMode: VoiceLensView.Mode {
        switch session.phase {
        case .listening: session.isAudioFlowing ? .live : .waiting
        case .finishing: .finishing
        default: .waiting
        }
    }
}

/// The words, large. Committed words in the primary colour; the one word the
/// recognizer may still revise in secondary. Anchored to the bottom so new text never
/// makes the layout jump, and updated in place (no per-update animation, which reads
/// as flicker at recognition rate).
private struct VoiceTranscriptView: View {
    let transcript: VoiceTranscript
    let isFinal: Bool

    var body: some View {
        ScrollView {
            Group {
                if transcript.text.isEmpty {
                    Text("বলুন…")
                        .foregroundStyle(.tertiary)
                } else {
                    Text(attributed)
                }
            }
            .font(.system(size: 28))
            .lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .textSelection(.enabled)
        }
        .defaultScrollAnchor(.bottom)
        .scrollIndicators(.hidden)
        .accessibilityLabel(transcript.text.isEmpty ? "Listening" : transcript.text)
    }

    private var attributed: AttributedString {
        let committed = isFinal ? transcript.text : String(transcript.stableText)
        let tail = isFinal ? "" : String(transcript.text.dropFirst(transcript.stableLength))
        var text = AttributedString(committed)
        text.foregroundColor = .primary
        var pending = AttributedString(tail)
        pending.foregroundColor = .secondary
        text.append(pending)
        return text
    }
}

/// Sits at the top safe-area edge, below the system's back-to-app control.
/// Use an upward arrow: a diagonal arrow elsewhere on screen does not identify
/// that control. The hint is instructional, not a replacement back button.
private struct ReturnHint: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "arrow.up")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text("Tap ◀ above to insert")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text("The microphone is off.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Dictation ready. Use the system back-to-app button at the top left to return and insert your text. The microphone is off.")
    }
}

/// Permission, model, or microphone problems, each with the one action that fixes it.
private struct VoiceFailureView: View {
    let failure: VoiceSessionFailure
    @ObservedObject var models: VoiceModelLibrary

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: failure == .noStreamingModel ? "arrow.down.circle" : "mic.slash")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            switch failure {
            case .noStreamingModel:
                Text("Download Bangla Voice").font(.title3.weight(.semibold))
                Text("A one-time download of \(ByteCountFormatter.string(fromByteCount: models.defaultSetDownloadBytes, countStyle: .file)). Voice typing then works entirely on this iPhone.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                VoiceModelSetupButton(models: models)
            case .microphonePermissionDenied:
                Text("Microphone Access Is Off").font(.title3.weight(.semibold))
                Text("Allow the microphone for Obadh in Settings to dictate.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(.borderedProminent)
            case .audioEngineFailed, .interrupted:
                Text(failure == .interrupted ? "Another App Is Using the Microphone" : "The Microphone Couldn't Start")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding(.horizontal, 32)
    }
}

/// Downloads the default model set, showing combined progress.
struct VoiceModelSetupButton: View {
    @ObservedObject var models: VoiceModelLibrary

    var body: some View {
        switch models.defaultSetStatus {
        case .downloading(let progress):
            ProgressView(value: progress).frame(maxWidth: 240)
        case .installed:
            Label("Downloaded", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
        default:
            Button("Download") { models.downloadDefaultSet() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }
}
