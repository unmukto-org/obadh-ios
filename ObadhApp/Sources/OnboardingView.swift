import SwiftUI

/// First-run setup. Three questions, asked once: do you want it, is it added, do you
/// want haptics. Nothing here is ever shown again.
struct OnboardingView: View {
    /// One setup step, not two. `Settings › Obadh › Keyboards` enables the keyboard and
    /// Full Access on the same screen, so splitting them sent the user to the same place
    /// twice.
    private enum Step: String {
        case welcome
        case setup
        case done
    }

    /// Onboarding is a single centred column on every device. iPad does not get a
    /// wider one: this is a few lines of copy and one button, and stretching that
    /// across a 13-inch screen reads as an iPhone app that was never looked at.
    private static let contentColumnWidth: CGFloat = 460

    let install: KeyboardInstallState
    let onFinish: () -> Void

    @Environment(\.colorScheme) private var scheme
    /// Regular width means iPad. There the page is tall enough that pinning the
    /// button to the bottom edge leaves more than half the screen empty between it
    /// and the content, so the two are grouped instead.
    @Environment(\.horizontalSizeClass) private var widthClass
    @State private var step: Step
    @State private var isRevealed = false

    private var isRoomy: Bool { widthClass == .regular }

    init(install: KeyboardInstallState, onFinish: @escaping () -> Void) {
        self.install = install
        self.onFinish = onFinish
        _step = State(initialValue: Self.initialStep)
    }

    /// Resumes where the user left off. Walking to Settings to enable the keyboard kills
    /// this process, so a cold launch mid-setup is the normal path, not an edge case.
    ///
    /// Debug builds can also jump straight to a step for screenshots, since onboarding
    /// can't be driven without a mouse: `--onboarding-step=setup`. Compiled out of Release.
    private static var initialStep: Step {
        #if DEBUG
        let prefix = "--onboarding-step="
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }) {
            switch argument.dropFirst(prefix.count) {
            case "setup": return .setup
            case "done": return .done
            default: break
            }
        }
        #endif
        let raw = UserDefaults.standard.string(forKey: AppSetupState.onboardingStepKey)
        return raw.flatMap(Step.init(rawValue:)) ?? .welcome
    }

    var body: some View {
        ZStack {
            BrandBackground()

            VStack(spacing: 0) {
                content
                    // Pad first, then fill. The other order expands the content to the
                    // full width and *then* insets the result, pushing text off both
                    // edges.
                    .padding(.horizontal, 30)
                    .frame(maxWidth: Self.contentColumnWidth)
                    .frame(maxWidth: .infinity)
                    // Recreating on `step` is what drives the transition below.
                    .id(step)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 18)),
                            removal: .opacity.combined(with: .offset(y: -14))
                        )
                    )

                // On iPad the button belongs WITH the content, not at the far edge of
                // a 1194pt page: pinned to the bottom it left 55% of the screen empty
                // between the two, which reads as a layout nobody looked at.
                if isRoomy {
                    actionsColumn.padding(.top, 48)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !isRoomy {
                actionsColumn
                    .padding(.bottom, 14)
            }
        }
        .onAppear { isRevealed = true }
        .onChange(of: install) { _, state in
            // The user just came back from Settings having added it. Let the check mark
            // land before moving on, so the confirmation is seen rather than inferred.
            guard step == .setup, state.isKeyboardInstalled else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(800))
                advance(to: .done)
            }
        }
    }

    // MARK: - Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcome
        case .setup: setup
        case .done: done
        }
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            BrandMark()
                .reveal(0, isVisible: isRevealed)

            Text("Obadh")
                .font(BrandFont.wordmark(58))
                .tracking(-0.5)
                .foregroundStyle(BrandGradient.wordmark(scheme))
                .padding(.top, 34)
                .reveal(1, isVisible: isRevealed)

            Text("ভাষা হোক আরও উন্মুক্ত")
                .font(BrandFont.bangla(21))
                .foregroundStyle(scheme == .dark ? Color.obadhTealLight : Color.obadhDeep)
                .opacity(0.9)
                .padding(.top, 10)
                .reveal(2, isVisible: isRevealed)
        }
    }

    /// The numbered rows mirror what `Settings › Obadh` actually shows once the button
    /// opens it: a Keyboards row, and behind it both switches.
    private var setup: some View {
        VStack(spacing: 0) {
            title("Add Obadh to\nyour keyboards")

            // The diagram carries the instructions, so the numbered list is gone.
            SetupWalkthrough()
                .padding(.top, 26)

            Group {
                if install.isKeyboardInstalled {
                    // The instructions have done their job. Repeating them next to a green
                    // check reads as the app arguing with itself.
                    confirmation("Obadh is added")
                } else {
                    // Settings' own wording, so the sentence and the switch the user is
                    // hunting for read the same.
                    Text("Allow Full Access to enable haptics.")
                        .font(BrandFont.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.top, 20)
        }
    }

    private var done: some View {
        VStack(spacing: 0) {
            if install.isKeyboardInstalled {
                halo("checkmark.seal.fill", tint: .green)
                title("You're all set")
                    .padding(.top, 28)
                message("Tap the globe key to switch to Obadh.")
                    .padding(.top, 14)
            } else {
                halo("keyboard")
                title("Ready when you are")
                    .padding(.top, 28)
                message("Turn Obadh on any time in Settings › Keyboards.")
                    .padding(.top, 14)
            }
        }
    }

    // MARK: - Actions

    /// The buttons, in the same column as the content. Without the width cap they
    /// track the window instead: `BrandButtonStyle` fills its container, so on a
    /// 13-inch iPad in landscape "Get Started" became a 1316pt capsule under text
    /// that was 460pt wide.
    private var actionsColumn: some View {
        actions
            .padding(.horizontal, 30)
            .frame(maxWidth: Self.contentColumnWidth)
            .frame(maxWidth: .infinity)
            .reveal(5, isVisible: isRevealed)
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 6) {
            switch step {
            case .welcome:
                primaryButton("Get Started") { advance(to: .setup) }

            case .setup:
                if install.isKeyboardInstalled {
                    primaryButton("Continue") { advance(to: .done) }
                } else {
                    primaryButton("Open Settings", action: openSystemSettings)
                    // Without this the step is a trap: a user who cannot add the keyboard
                    // right now has no way forward.
                    secondaryButton("Not now") { advance(to: .done) }
                }

            case .done:
                primaryButton("Done", action: onFinish)
            }
        }
    }

    private func advance(to next: Step) {
        // Persist before animating: the very next thing the user does on the setup step
        // is leave for Settings, which may not return to this process.
        UserDefaults.standard.set(next.rawValue, forKey: AppSetupState.onboardingStepKey)
        withAnimation(.smooth(duration: 0.45)) { step = next }
    }

    // MARK: - Pieces

    private func halo(_ symbol: String, tint: Color = .obadhTeal) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 46, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(scheme == .dark ? tint : Color.obadhDeep)
            .frame(width: 112, height: 112)
            .background(
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(Circle().stroke(tint.opacity(0.25), lineWidth: 1))
            )
            .shadow(color: tint.opacity(0.22), radius: 24, y: 8)
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(BrandFont.title)
            .tracking(-0.4)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(BrandFont.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func confirmation(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .foregroundStyle(.green)
            .transition(.scale.combined(with: .opacity))
    }

    @ViewBuilder
    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        if #available(iOS 26.0, *) {
            Button(action: action) {
                Text(title).frame(maxWidth: .infinity)
            }
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .controlSize(.large)
            .tint(Color.obadhDeep)
            .buttonStyle(.glassProminent)
        } else {
            Button(title, action: action)
                .buttonStyle(BrandButtonStyle())
        }
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(BrandFont.body)
            .foregroundStyle(.secondary)
            .padding(.vertical, 12)
    }
}
