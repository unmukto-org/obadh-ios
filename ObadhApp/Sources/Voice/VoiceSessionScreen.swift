import SwiftUI
import UIKit

/// The voice screen the keyboard's mic opens. It is already listening when it
/// appears; the words show here as they are recognized; Done (or a pause) releases
/// the microphone, and ◀ Back hands the text to the keyboard. Standard sheet
/// anatomy (Cancel and Done up top), large text, and the voice light below.
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
                footer
            }
        }
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    // MARK: Header: Cancel · Done, like any system sheet

    private var header: some View {
        HStack {
            Button("Cancel") {
                session.cancelDictation()
                onClose()
            }
            Spacer()
            if session.phase == .listening {
                Button("Done") { session.finishDictation() }
                    .fontWeight(.semibold)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
    }

    // MARK: Footer: the light while listening, the way back once done

    @ViewBuilder private var footer: some View {
        if session.hasFinalText {
            ReturnHint()
                .padding(.bottom, 28)
                .transition(.opacity)
        } else {
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

/// Points at the system's ◀ back button, the only way back iOS offers.
private struct ReturnHint: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var nudge = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.up.backward")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.tint)
                .offset(x: nudge ? -3 : 0, y: nudge ? -3 : 0)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: nudge)
            Text("Tap ◀ at the top left to insert")
                .font(.headline)
            Text("The microphone is off.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .task { nudge = true }
        .accessibilityElement(children: .combine)
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
