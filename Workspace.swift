import ProjectDescription

/// Tuist.swift alone does not make `tuist generate` at the repo root discover
/// App/Project.swift — without a workspace listing it explicitly, `tuist
/// generate` falls back to previewing the root Package.swift instead.
let workspace = Workspace(
    name: "Auricle",
    projects: ["App"],
)
