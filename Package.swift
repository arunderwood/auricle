// swift-tools-version: 6.3
// AuricleKit — single SwiftPM library, 26 modular targets per AR-INIT-5.
// Module boundaries are the architecture: cross-target imports declared here are
// the ONLY intended imports. Plain `swift build` does not reject an undeclared
// cross-edge — that needs `--explicit-target-dependency-import-check error`,
// which Story 1.8 wires into CI so the boundary becomes build-enforced there.
//
// MARK: - Deferred to v1.1 (AR-INIT-2)

// Sparkle: https://github.com/sparkle-project/Sparkle.git from: "2.10.0"

import PackageDescription

let package = Package(
    name: "AuricleKit",
    platforms: [.macOS(.v14)],
    products: [
        // One library product per source target — Xcode targets link these by name.
        .library(name: "Core", targets: ["Core"]),
        .library(name: "State", targets: ["State"]),
        .library(name: "Telemetry", targets: ["Telemetry"]),
        .library(name: "Orchestrator", targets: ["Orchestrator"]),
        .library(name: "Permissions", targets: ["Permissions"]),
        .library(name: "Capture", targets: ["Capture"]),
        .library(name: "TranscriberInterface", targets: ["TranscriberInterface"]),
        .library(name: "DiarizerInterface", targets: ["DiarizerInterface"]),
        .library(name: "SummarizerInterface", targets: ["SummarizerInterface"]),
        .library(name: "AIReviewerInterface", targets: ["AIReviewerInterface"]),
        .library(name: "CalendarInterface", targets: ["CalendarInterface"]),
        .library(name: "Transcribe", targets: ["Transcribe"]),
        .library(name: "Diarize", targets: ["Diarize"]),
        .library(name: "Attribute", targets: ["Attribute"]),
        .library(name: "Summarize", targets: ["Summarize"]),
        .library(name: "Persist", targets: ["Persist"]),
        .library(name: "Pipeline", targets: ["Pipeline"]),
        .library(name: "Verify", targets: ["Verify"]),
        .library(name: "Notifications", targets: ["Notifications"]),
        .library(name: "ReviewDiarization", targets: ["ReviewDiarization"]),
        .library(name: "ClaudeSummarizer", targets: ["ClaudeSummarizer"]),
        .library(name: "ClaudeAIReviewers", targets: ["ClaudeAIReviewers"]),
        .library(name: "WhisperKitTranscriber", targets: ["WhisperKitTranscriber"]),
        .library(name: "WhisperKitDiarizer", targets: ["WhisperKitDiarizer"]),
        .library(name: "GoogleCalendarSource", targets: ["GoogleCalendarSource"]),
        .library(name: "VaultGlossary", targets: ["VaultGlossary"]),
        .library(name: "TestSupport", targets: ["TestSupport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.1.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
        .package(url: "https://github.com/yaslab/ULID.swift.git", from: "1.3.1"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.0"),
    ],
    targets: [
        // === Cross-cutting ===
        .target(
            name: "Core",
            dependencies: [
                .product(name: "TOMLKit", package: "TOMLKit"),
                .product(name: "ULID", package: "ULID.swift"), // wrapped as `ULIDFormat` — see Sources/Core/ULIDFormat.swift
            ],
            path: "Sources/Core",
        ),
        .target(name: "State", dependencies: ["Core", .product(name: "GRDB", package: "GRDB.swift")], path: "Sources/State"),
        .target(name: "Telemetry", dependencies: ["Core", "State", .product(name: "GRDB", package: "GRDB.swift")], path: "Sources/Telemetry"),
        .target(
            name: "Orchestrator",
            dependencies: ["Core", "State", "Telemetry", "Permissions", .product(name: "ArgumentParser", package: "swift-argument-parser")],
            path: "Sources/Orchestrator",
        ),
        .target(name: "Permissions", dependencies: ["Core"], path: "Sources/Permissions"),

        // === Capture ===
        .target(name: "Capture", dependencies: ["Core", "State", "Telemetry", "Permissions"], path: "Sources/Capture"),

        // === Strategy interfaces (protocol-only — no concrete deps) ===
        .target(name: "TranscriberInterface", dependencies: ["Core"], path: "Sources/TranscriberInterface"),
        .target(name: "DiarizerInterface", dependencies: ["Core"], path: "Sources/DiarizerInterface"),
        .target(name: "SummarizerInterface", dependencies: ["Core"], path: "Sources/SummarizerInterface"),
        .target(name: "AIReviewerInterface", dependencies: ["Core", "DiarizerInterface", "TranscriberInterface"], path: "Sources/AIReviewerInterface"),
        .target(name: "CalendarInterface", dependencies: ["Core"], path: "Sources/CalendarInterface"),

        // === Stages ===
        .target(name: "Transcribe", dependencies: ["Core", "State", "Telemetry", "Orchestrator", "TranscriberInterface", "DiarizerInterface"], path: "Sources/Transcribe"),
        .target(name: "Diarize", dependencies: ["Core", "State", "Telemetry", "DiarizerInterface"], path: "Sources/Diarize"),
        .target(
            name: "Attribute",
            dependencies: ["Core", "State", "Telemetry", "Orchestrator", "DiarizerInterface", "AIReviewerInterface", "VaultGlossary"],
            path: "Sources/Attribute",
        ),
        .target(
            name: "Summarize",
            dependencies: ["Core", "State", "Telemetry", "Orchestrator", "SummarizerInterface", "AIReviewerInterface", "CalendarInterface", "VaultGlossary"],
            path: "Sources/Summarize",
            resources: [.copy("Prompts")],
        ),
        .target(
            name: "Persist",
            dependencies: ["Core", "State", "Telemetry", "Orchestrator", .product(name: "Yams", package: "Yams")],
            path: "Sources/Persist",
        ),
        .target(
            name: "Pipeline",
            dependencies: [
                "Core", "State", "Telemetry", "Orchestrator", "Attribute", "Persist", "Notifications", "Transcribe", "TranscriberInterface",
                "ReviewDiarization", "AIReviewerInterface", "Summarize", "SummarizerInterface", "CalendarInterface",
            ],
            path: "Sources/Pipeline",
        ),
        .target(name: "Verify", dependencies: ["Core", "State", "Telemetry"], path: "Sources/Verify"),
        .target(name: "Notifications", dependencies: ["Core", "State", "Orchestrator", "Telemetry"], path: "Sources/Notifications"),
        .target(
            name: "ReviewDiarization",
            dependencies: ["Core", "State", "Telemetry", "Orchestrator", "AIReviewerInterface", "DiarizerInterface"],
            path: "Sources/ReviewDiarization",
        ),

        // === Concrete strategies ===
        .target(name: "ClaudeSummarizer", dependencies: ["Core", "SummarizerInterface", "VaultGlossary", "Summarize"], path: "Sources/ClaudeSummarizer"),
        .target(
            name: "ClaudeAIReviewers",
            dependencies: ["Core", "AIReviewerInterface", "DiarizerInterface", "ClaudeSummarizer", "SummarizerInterface"],
            path: "Sources/ClaudeAIReviewers",
        ),
        .target(
            name: "WhisperKitTranscriber",
            dependencies: [
                "Core", "TranscriberInterface",
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/WhisperKitTranscriber",
        ),
        .target(
            name: "WhisperKitDiarizer",
            dependencies: [
                "Core", "DiarizerInterface",
                .product(name: "SpeakerKit", package: "WhisperKit"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/WhisperKitDiarizer",
        ),
        .target(name: "GoogleCalendarSource", dependencies: ["Core", "CalendarInterface"], path: "Sources/GoogleCalendarSource"),
        .target(name: "VaultGlossary", dependencies: ["Core"], path: "Sources/VaultGlossary"),

        // === Test support ===
        .target(name: "TestSupport", dependencies: ["Core"], path: "Sources/TestSupport"),

        // === Test targets (one per source target) ===
        .testTarget(name: "CoreTests", dependencies: ["Core", "TestSupport", "ClaudeSummarizer"], path: "Tests/CoreTests"),
        .testTarget(name: "StateTests", dependencies: ["State", "TestSupport"], path: "Tests/StateTests"),
        .testTarget(name: "TelemetryTests", dependencies: ["Telemetry", "TestSupport"], path: "Tests/TelemetryTests"),
        .testTarget(
            name: "OrchestratorTests",
            dependencies: ["Orchestrator", "TestSupport", .product(name: "ArgumentParser", package: "swift-argument-parser")],
            path: "Tests/OrchestratorTests",
        ),
        .testTarget(name: "PermissionsTests", dependencies: ["Permissions", "TestSupport"], path: "Tests/PermissionsTests"),
        .testTarget(
            name: "CaptureTests",
            dependencies: [
                "Capture", "TestSupport", "Core", "State", "Telemetry",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/CaptureTests",
        ),
        // Interface-only target — protocol declarations only; tests minimal/none. AR-PAT-1.
        .testTarget(name: "TranscriberInterfaceTests", dependencies: ["TranscriberInterface", "TestSupport"], path: "Tests/TranscriberInterfaceTests"),
        // Interface-only target — protocol declarations only; tests minimal/none. AR-PAT-1.
        .testTarget(name: "DiarizerInterfaceTests", dependencies: ["DiarizerInterface", "Core", "TestSupport"], path: "Tests/DiarizerInterfaceTests"),
        // Interface-only target — protocol declarations only; tests minimal/none. AR-PAT-1.
        .testTarget(name: "SummarizerInterfaceTests", dependencies: ["SummarizerInterface", "TestSupport"], path: "Tests/SummarizerInterfaceTests"),
        // Interface-only target — protocol declarations only; tests minimal/none. AR-PAT-1.
        .testTarget(name: "AIReviewerInterfaceTests", dependencies: ["AIReviewerInterface", "Core", "DiarizerInterface", "TestSupport"], path: "Tests/AIReviewerInterfaceTests"),
        // Interface-only target — protocol declarations only; tests minimal/none. AR-PAT-1.
        .testTarget(name: "CalendarInterfaceTests", dependencies: ["CalendarInterface", "TestSupport"], path: "Tests/CalendarInterfaceTests"),
        .testTarget(
            name: "TranscribeTests",
            dependencies: [
                "Transcribe", "TestSupport", "Core", "State", "Orchestrator", "Telemetry", "TranscriberInterface", "WhisperKitTranscriber",
                "Diarize", "DiarizerInterface",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/TranscribeTests",
        ),
        .testTarget(
            name: "DiarizeTests",
            dependencies: [
                "Diarize", "TestSupport", "Core", "DiarizerInterface", "Telemetry", "WhisperKitDiarizer",
            ],
            path: "Tests/DiarizeTests",
        ),
        .testTarget(
            name: "AttributeTests",
            dependencies: [
                "Attribute", "TestSupport", "Core", "State", "Orchestrator", "Telemetry", "AIReviewerInterface", "DiarizerInterface",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/AttributeTests",
            resources: [.copy("Fixtures")],
        ),
        .testTarget(
            name: "SummarizeTests",
            dependencies: [
                "Summarize", "TestSupport", "ClaudeSummarizer", "Orchestrator", "State", "Persist", "CalendarInterface", "AIReviewerInterface",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/SummarizeTests",
            resources: [.copy("Snapshots"), .copy("Fixtures")],
        ),
        .testTarget(name: "ClaudeSummarizerTests", dependencies: ["ClaudeSummarizer", "TestSupport", "Summarize"], path: "Tests/ClaudeSummarizerTests"),
        .testTarget(
            name: "ClaudeAIReviewersTests",
            dependencies: [
                "ClaudeAIReviewers", "TestSupport", "Core", "AIReviewerInterface", "DiarizerInterface",
                "ClaudeSummarizer", "SummarizerInterface",
            ],
            path: "Tests/ClaudeAIReviewersTests",
        ),
        .testTarget(
            name: "ReviewDiarizationTests",
            dependencies: [
                "ReviewDiarization", "TestSupport", "Core", "State", "Orchestrator", "Telemetry", "AIReviewerInterface", "DiarizerInterface",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/ReviewDiarizationTests",
        ),
        .testTarget(
            name: "WhisperKitTranscriberTests",
            dependencies: [
                "WhisperKitTranscriber", "TestSupport", "Core", "TranscriberInterface",
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Tests/WhisperKitTranscriberTests",
        ),
        .testTarget(
            name: "WhisperKitDiarizerTests",
            dependencies: [
                "WhisperKitDiarizer", "TestSupport", "Core", "DiarizerInterface",
                .product(name: "SpeakerKit", package: "WhisperKit"),
            ],
            path: "Tests/WhisperKitDiarizerTests",
        ),
        // Summarize and its collaborators: the real source is run through the real stage.
        .testTarget(
            name: "GoogleCalendarSourceTests",
            dependencies: [
                "GoogleCalendarSource", "CalendarInterface", "TestSupport", "Core", "Summarize", "SummarizerInterface", "State", "Orchestrator", "Telemetry",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/GoogleCalendarSourceTests",
        ),
        .testTarget(name: "VaultGlossaryTests", dependencies: ["VaultGlossary", "Core", "TestSupport"], path: "Tests/VaultGlossaryTests"),
        .testTarget(
            name: "PersistTests",
            dependencies: ["Persist", "TestSupport", "Orchestrator", "State", .product(name: "GRDB", package: "GRDB.swift")],
            path: "Tests/PersistTests",
        ),
        .testTarget(
            name: "PipelineTests",
            dependencies: [
                "Pipeline", "TestSupport", "Core", "State", "Orchestrator", "Telemetry", "Attribute", "Persist", "Notifications",
                "DiarizerInterface", "Transcribe", "TranscriberInterface", "ReviewDiarization", "AIReviewerInterface", "Summarize",
                "SummarizerInterface", "CalendarInterface",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/PipelineTests",
        ),
        .testTarget(
            name: "IntegrationTests",
            dependencies: [
                "Pipeline", "TestSupport", "Core", "State", "Orchestrator", "Telemetry", "Attribute", "Persist", "Notifications",
                "Capture", "Transcribe", "TranscriberInterface", "Diarize", "DiarizerInterface", "ReviewDiarization", "AIReviewerInterface",
                "Summarize", "SummarizerInterface", "ClaudeSummarizer",
            ],
            path: "Tests/IntegrationTests",
            resources: [.copy("Fixtures")],
        ),
        .testTarget(name: "VerifyTests", dependencies: ["Verify", "TestSupport"], path: "Tests/VerifyTests"),
        .testTarget(
            name: "NotificationsTests",
            dependencies: ["Notifications", "TestSupport", "Core", "State", "Orchestrator", "Telemetry", .product(name: "GRDB", package: "GRDB.swift")],
            path: "Tests/NotificationsTests",
        ),
    ],
)
