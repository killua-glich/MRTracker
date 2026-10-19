//
//  ProjectPathFormatting.swift
//  Shared (MyApp + MRTrackerWidgetExtension)
//
//  Pure formatting helper for `MergeRequestSnapshot.projectPath` (e.g.
//  "group/backend-api") into the short form shown in the menu bar popup's Project
//  column (PLAN.md → "Menu bar popup": "Project name (path, shortened)"). Kept as a
//  free function rather than inline in `MergeRequestRow` so `MergeRequestListTests` can
//  exercise it without touching any view code.
//

import Foundation

nonisolated enum ProjectPathFormatting {
    /// The last path component of a GitLab project path, e.g. `"group/backend-api"` →
    /// `"backend-api"`, `"group/subgroup/codefair"` → `"codefair"`. A path with no `/` at
    /// all (unexpected, but shouldn't crash) is returned unchanged. The full path is still
    /// shown elsewhere (the row's `.help` tooltip) so no information is lost, only
    /// shortened for the fixed-width column.
    static func shortName(_ projectPath: String) -> String {
        projectPath.split(separator: "/").last.map(String.init) ?? projectPath
    }
}
