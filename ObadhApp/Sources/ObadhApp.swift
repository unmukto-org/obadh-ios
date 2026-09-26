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
            switch argument.dropFirst(screenPrefix.count) {
            case "settings":
                return UIHostingController(rootView: SettingsView(install: KeyboardInstallStateReader().read()))
            case "about":
                return UIHostingController(rootView: NavigationStack { AboutView() })
            case "privacy":
                return UIHostingController(rootView: NavigationStack { PrivacyView() })
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
