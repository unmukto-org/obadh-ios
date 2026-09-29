// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ObadhIOSSupport",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "ObadhKeyboardCore", targets: ["ObadhKeyboardCore"]),
        .executable(name: "typing-accuracy-report", targets: ["TypingAccuracyReport"])
    ],
    targets: [
        .target(name: "TypingAccuracyMetrics", path: "Tools/TypingAccuracy/Core"),
        .executableTarget(name: "TypingAccuracyReport", dependencies: ["TypingAccuracyMetrics"], path: "Tools/TypingAccuracy/Report"),
        .testTarget(name: "TypingAccuracyMetricsTests", dependencies: ["TypingAccuracyMetrics"]),
        .target(
            name: "ObadhKeyboardCore",
            path: "Shared/Sources",
            exclude: [
                "Design",
                "VoiceUI",
                "VoiceActivity",
                "Keyboard/Emoji/EmojiPanelView.swift",
                "Keyboard/Emoji/EmojiVariantPopoverView.swift",
                "Keyboard/KeyboardDebugChannel.swift",
                "Settings/KeyboardSizingLog.swift",
                "Settings/KeystrokeProfile.swift",
                "Keyboard/KeyboardFeedbackController.swift",
                "Keyboard/KeyboardKeyButton.swift",
                "Keyboard/KeyboardKeyPreviewCallout.swift",
                "Keyboard/KeyboardRowView.swift",
                "Keyboard/KeyboardTouchSurfaceView.swift",
                "Keyboard/SuggestionBarView.swift",
                "Keyboard/VoiceStripIndicatorView.swift",
                "Engine/ObadhBridgeClient.swift"
            ]
        ),
        .testTarget(
            name: "ObadhKeyboardCoreTests",
            dependencies: ["ObadhKeyboardCore"]
        )
    ]
)
