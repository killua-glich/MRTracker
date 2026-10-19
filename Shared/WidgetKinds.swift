import Foundation

/// WidgetKit `kind` strings, shared by the widget extension (its `StaticConfiguration`) and
/// the host app (`WidgetCenter.shared.reloadTimelines(ofKind:)`, MRT-041). One constant so
/// the two can never drift apart — a mismatched kind silently reloads nothing.
nonisolated enum WidgetKinds {
    /// The merge request list widget (MRTrackerWidget/MRTrackerWidget.swift).
    static let mergeRequests = "MRTrackerWidget"
}
