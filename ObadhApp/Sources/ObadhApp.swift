import SwiftUI
import UIKit

@main
enum ObadhMain {
    static func main() {
        UIApplicationMain(
            CommandLine.argc,
            CommandLine.unsafeArgv,
            NSStringFromClass(ObadhApplication.self),
            NSStringFromClass(ObadhAppDelegate.self)
        )
    }
}

final class ObadhApplication: UIApplication {
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {}

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {}

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {}

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {}

    override var keyCommands: [UIKeyCommand]? {
        []
    }
}

final class ObadhAppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = ObadhSceneDelegate.self
        return configuration
    }

    /// iOS relaunched us to deliver finished model downloads.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == VoiceModelDownloader.sessionIdentifier else {
            completionHandler()
            return
        }
        MainActor.assumeIsolated {
            let downloader = VoiceModelLibrary.shared.downloader
            downloader.backgroundCompletionHandler = completionHandler
        }
    }
}

final class ObadhSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = makeRootViewController()
        window.makeKeyAndVisible()
        self.window = window

        // A fresh process holds no microphone: a session badge still on screen belongs
        // to a process that was killed.
        if VoiceSessionController.shared.phase == .idle {
            VoiceLiveActivityPresenter.shared.endStale()
        }

        #if DEBUG
        VoiceSelfTest.runIfRequested()
        #endif

        // Cold launch from the keyboard's mic: the URL arrives with the connection.
        if let url = connectionOptions.urlContexts.first?.url {
            handle(url)
        }

        #if DEBUG
        // Fires a settings URL without a tap, so where iOS actually lands can be
        // observed. `--open-url=app|notifications|defaults|<literal url>`.
        let defaultAppsURL = if #available(iOS 18.3, *) {
            UIApplication.openDefaultApplicationsSettingsURLString
        } else {
            ""
        }
        NSLog("OBADH-URLS app=%@ notifications=%@ defaults=%@",
              UIApplication.openSettingsURLString,
              UIApplication.openNotificationSettingsURLString,
              defaultAppsURL)

        let prefix = "--open-url="
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }) {
            let raw = String(argument.dropFirst(prefix.count))
            let target: String
            switch raw {
            case "app": target = UIApplication.openSettingsURLString
            case "notifications": target = UIApplication.openNotificationSettingsURLString
            case "defaults": target = defaultAppsURL
            default: target = raw
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let url = URL(string: target) else { return }
                UIApplication.shared.open(url) { ok in
                    NSLog("OBADH-URLS opened=%@ success=%@", target, ok ? "yes" : "no")
                }
            }
        }
        #endif
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        handle(url)
    }

    /// Returning to the app some other way (the icon, the switcher) after the voice
    /// screen did its job shows the normal app, not a stale listening screen.
    func sceneWillEnterForeground(_ scene: UIScene) {
        guard voiceScreen != nil, VoiceSessionController.shared.phase != .listening else { return }
        dismissVoiceScreen()
    }

    private weak var voiceScreen: UIViewController?

    private func handle(_ url: URL) {
        guard url.scheme == VoiceSessionChannel.urlScheme, url.host == VoiceSessionChannel.urlHost else { return }
        presentVoiceScreen()
        VoiceSessionController.shared.handleVoiceURL(url)
    }

    private func presentVoiceScreen() {
        guard voiceScreen == nil, let root = window?.rootViewController else { return }
        let screen = UIHostingController(rootView: VoiceSessionScreen(
            session: .shared,
            models: .shared,
            onClose: { [weak self] in self?.dismissVoiceScreen() }
        ))
        screen.modalPresentationStyle = .fullScreen
        var top = root
        while let presented = top.presentedViewController { top = presented }
        top.present(screen, animated: false)
        voiceScreen = screen
    }

    private func dismissVoiceScreen() {
        voiceScreen?.dismiss(animated: true)
        voiceScreen = nil
    }

    private func makeRootViewController() -> UIViewController {
        // Measurement and test harnesses reachable only by launch argument, and only
        // in Debug. Release has no text input anywhere in the app.
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--keyboard-geometry-probe")
            || arguments.contains("--native-keyboard-geometry-probe") {
            return KeyboardGeometryProbeViewController()
        }

        if arguments.contains("--keyboard-test") {
            return OrientationPinningNavigationController(rootViewController: KeyboardTestViewController())
        }

        // Leaf screens sit behind taps, which cannot be scripted. Open them directly for
        // review: `--screen=about`.
        let screenPrefix = "--screen="
        if let argument = arguments.first(where: { $0.hasPrefix(screenPrefix) }) {
            let screen = argument.dropFirst(screenPrefix.count)
            if screen.hasPrefix("voice-panel") {
                let phase: VoicePanelPhase = switch screen.split(separator: ":").last {
                case "ready": .ready
                case "finishing": .finishing
                case "connecting": .connecting
                case "problem": .problem("অবাধ অ্যাপে ভয়েস মডেল ডাউনলোড করুন")
                default: .listening
                }
                return UIHostingController(rootView: VoicePanelPreviewView(phase: phase))
            }
            switch screen {
            case "settings":
                return UIHostingController(rootView: SettingsView(install: KeyboardInstallStateReader().read()))
            case "about":
                return UIHostingController(rootView: NavigationStack { AboutView() })
            case "privacy":
                return UIHostingController(rootView: NavigationStack { PrivacyView() })
            case "voice-settings":
                return UIHostingController(rootView: NavigationStack { VoiceSettingsView() })
            case "voice-session":
                return UIHostingController(rootView: VoiceSessionScreen(session: .shared, models: .shared, onClose: {}))
            default:
                break
            }
        }
        // No launch argument: a Debug build opens straight into the tuning screen
        // (keyboard + haptic/key-tint sliders), bypassing onboarding, so the debug
        // controls are always reachable by just tapping the app icon.
        return OrientationPinningNavigationController(rootViewController: KeyboardTestViewController())
        #else
        return UIHostingController(rootView: RootView())
        #endif
    }
}
