import SwiftUI
import UIKit

/// Shown when the keyboard bounces into the app to start the microphone. Its whole
/// job is to confirm "listening" and send the user straight back: iOS offers no way
/// to return automatically, only the "◀ App" breadcrumb at the top left.
struct VoiceSessionScreen: View {
    @ObservedObject var session: VoiceSessionController
    @ObservedObject var models: VoiceModelLibrary
    var onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var nudge = false

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 0) {
                backCue
                    .padding(.top, 6)
                Spacer(minLength: 24)
                content
                Spacer(minLength: 24)
                controls
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 24)
        }
    }

    // MARK: Back cue

    /// Points at the system breadcrumb, which sits just above this at the top left.
    private var backCue: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.up.left")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(VoiceUIPalette.teal)
                .offset(x: nudge ? -4 : 0, y: nudge ? -4 : 0)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: nudge)
            VStack(alignment: .leading, spacing: 2) {
                Text("Tap ◀ at the top left to go back")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                Text("Keep talking. Your words appear where you were typing.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .onAppear { nudge = true }
        .accessibilityElement(children: .combine)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let failure = session.failure {
            failureView(failure)
        } else {
            VStack(spacing: 20) {
                // The same light as the keyboard's ribbon, as a band across the screen.
                VoiceLens(feed: session.levels, mode: lensMode)
                    .frame(height: 72)
                    .padding(.horizontal, -24)
                Text(statusText)
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                if !session.transcript.isEmpty {
                    Text(session.transcript)
                        .font(.system(size: 22))
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .truncationMode(.head)
                        .transition(.opacity)
                }
            }
            .animation(.smooth, value: session.transcript)
        }
    }

    private var lensMode: VoiceLensView.Mode {
        switch session.phase {
        case .listening, .ready: session.isAudioFlowing ? .live : .waiting
        case .finishing: .finishing
        case .idle, .starting: .waiting
        }
    }

    private var statusText: String {
        switch session.phase {
        case .idle, .starting: "Starting the microphone…"
        case .ready: "Microphone ready"
        case .listening: session.transcript.isEmpty ? "Listening. Speak in Bangla." : "Listening"
        case .finishing: "Finishing…"
        }
    }

    @ViewBuilder private func failureView(_ failure: VoiceSessionFailure) -> some View {
        VStack(spacing: 14) {
            Image(systemName: failure == .noStreamingModel ? "arrow.down.circle" : "mic.slash")
                .font(.system(size: 44))
                .foregroundStyle(VoiceUIPalette.teal)
            switch failure {
            case .noStreamingModel:
                Text("Download the voice models")
                    .font(.title3.weight(.semibold))
                Text("Voice typing runs entirely on this iPhone. It needs a one-time download of \(ByteCountFormatter.string(fromByteCount: models.defaultSetDownloadBytes, countStyle: .file)).")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                VoiceModelSetupButton(models: models)
            case .microphonePermissionDenied:
                Text("Microphone access is off")
                    .font(.title3.weight(.semibold))
                Text("Allow the microphone for Obadh in Settings to dictate.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(VoiceUIPalette.teal)
            case .audioEngineFailed, .interrupted:
                Text(failure == .interrupted ? "Another app took the microphone" : "The microphone could not start")
                    .font(.title3.weight(.semibold))
                Button("Try Again") {
                    Task { await session.startSession(thenDictate: session.dictationID) }
                }
                .buttonStyle(.borderedProminent)
                .tint(VoiceUIPalette.teal)
            }
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                session.endSession()
                onClose()
            } label: {
                Label("Turn Off Microphone", systemImage: "mic.slash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            if session.phase == .listening {
                Button {
                    session.finishDictation()
                } label: {
                    Label("Done", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(VoiceUIPalette.teal)
                .controlSize(.large)
            }
        }
    }
}

/// Downloads the default model set, showing combined progress.
struct VoiceModelSetupButton: View {
    @ObservedObject var models: VoiceModelLibrary

    var body: some View {
        let downloads = VoiceModelRole.allCases.compactMap {
            models.catalog.defaultModel(for: $0, deviceMemoryGiB: models.deviceMemoryGiB)
        }
        let progress = downloads.compactMap { model -> Double? in
            if case .downloading(let fraction) = models.state(of: model) { return fraction }
            return models.state(of: model) == .installed ? 1 : nil
        }
        let downloading = downloads.contains {
            if case .downloading = models.state(of: $0) { return true }
            return false
        }
        if downloading {
            ProgressView(value: progress.reduce(0, +) / Double(max(downloads.count, 1)))
                .tint(VoiceUIPalette.teal)
                .frame(maxWidth: 240)
        } else {
            Button("Download") { models.downloadDefaultSet() }
                .buttonStyle(.borderedProminent)
                .tint(VoiceUIPalette.teal)
                .controlSize(.large)
        }
    }
}
