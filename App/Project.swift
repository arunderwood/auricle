import ProjectDescription

// Every library product AuricleKit declares except TestSupport — both executables
// are full composition roots per AR-PAT-5: AuricleApp wires the GUI, auricle-cli
// exposes every stage per AR-PIPE-1, so both need the complete strategy set.
let auricleKitProducts: [TargetDependency] = [
    .package(product: "Core"),
    .package(product: "State"),
    .package(product: "Telemetry"),
    .package(product: "Orchestrator"),
    .package(product: "Permissions"),
    .package(product: "Capture"),
    .package(product: "TranscriberInterface"),
    .package(product: "DiarizerInterface"),
    .package(product: "SummarizerInterface"),
    .package(product: "AIReviewerInterface"),
    .package(product: "CalendarInterface"),
    .package(product: "Transcribe"),
    .package(product: "Diarize"),
    .package(product: "Attribute"),
    .package(product: "Summarize"),
    .package(product: "ReviewDiarization"),
    .package(product: "Persist"),
    .package(product: "Verify"),
    .package(product: "Notifications"),
    .package(product: "ClaudeSummarizer"),
    .package(product: "ClaudeAIReviewers"),
    .package(product: "WhisperKitTranscriber"),
    .package(product: "WhisperKitDiarizer"),
    .package(product: "GoogleCalendarSource"),
    .package(product: "VaultGlossary"),
]

let project = Project(
    name: "Auricle",
    packages: [
        .local(path: "..")
    ],
    settings: .settings(
        configurations: [
            .debug(name: .debug, xcconfig: "../config/Debug.xcconfig"),
            .release(name: .release, xcconfig: "../config/Release.xcconfig"),
        ],
        // Tuist injects its own build settings unless told not to, which would
        // silently shadow the xcconfigs and make the plain-text files a lie.
        defaultSettings: .none
    ),
    targets: [
        .target(
            name: "AuricleApp",
            destinations: [.mac],
            product: .app,
            bundleId: "com.auricle.app",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .file(path: "Auricle/Info.plist"),
            sources: ["Auricle/**"],
            entitlements: .file(path: "Auricle/Auricle.entitlements"),
            dependencies: auricleKitProducts
        ),
        .target(
            name: "auricle-cli",
            destinations: [.mac],
            product: .commandLineTool,
            bundleId: "com.auricle.cli",
            deploymentTargets: .macOS("14.0"),
            sources: ["auricle-cli/**"],
            dependencies: auricleKitProducts + [
                .package(product: "ArgumentParser")
            ]
        ),
    ]
)
