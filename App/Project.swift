import ProjectDescription

/// Every library product AuricleKit declares except TestSupport and AppUI — both
/// executables are full composition roots per AR-PAT-5: AuricleApp wires the GUI,
/// auricle-cli exposes every stage per AR-PIPE-1, so both need the complete
/// strategy set. AppUI is GUI-only view code, so it's added to AuricleApp's own
/// dependencies below rather than here, and auricle-cli never links it.
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
    .package(product: "RecallBench"),
    .package(product: "Pipeline"),
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
        .local(path: ".."),
    ],
    settings: .settings(
        configurations: [
            .debug(name: .debug, xcconfig: "../config/Debug.xcconfig"),
            .release(name: .release, xcconfig: "../config/Release.xcconfig"),
        ],
        // Tuist injects its own build settings unless told not to, which would
        // silently shadow the xcconfigs and make the plain-text files a lie.
        defaultSettings: .none,
    ),
    targets: [
        .target(
            name: "AuricleApp",
            destinations: [.mac],
            product: .app,
            bundleId: "com.auricle.app",
            // The process-tap floor (Story 5.2): `AudioHardwareCreateProcessTap`
            // requires 14.4, and SwiftPM's `SupportedPlatform.MacOSVersion` has
            // no `.v14_4` case, so Package.swift can't express it — Tuist's
            // string form here is the one place this floor is enforced.
            deploymentTargets: .macOS("14.4"),
            infoPlist: .file(path: "Auricle/Info.plist"),
            sources: ["Auricle/**"],
            copyFiles: [
                .executables(name: "Embed auricle-cli", subpath: ".", files: [.buildProduct(name: "auricle-cli", codeSignOnCopy: true)]),
            ],
            entitlements: .file(path: "Auricle/Auricle.entitlements"),
            dependencies: auricleKitProducts + [.package(product: "AppUI"), .target(name: "auricle-cli")],
        ),
        .target(
            name: "auricle-cli",
            destinations: [.mac],
            product: .commandLineTool,
            productName: "auricle-cli",
            bundleId: "com.auricle.cli",
            // See AuricleApp's own deploymentTargets comment above.
            deploymentTargets: .macOS("14.4"),
            sources: ["auricle-cli/**"],
            dependencies: auricleKitProducts + [
                .package(product: "ArgumentParser"),
            ],
        ),
    ],
)
