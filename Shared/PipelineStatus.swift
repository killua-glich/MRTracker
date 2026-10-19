import Foundation

/// The GitLab CI pipeline status for a merge request's head pipeline.
///
/// Mirrors GitLab's `Ci::Pipeline` status enum (see PLAN.md → GitLab API mapping,
/// `head_pipeline.status`). Decoding is defensive: any status string GitLab returns that
/// isn't one of the known cases below is preserved via `.unknown(String)` rather than
/// failing the whole snapshot decode. GitLab has added pipeline statuses over time
/// (`scheduled`, `waiting_for_resource`, ...), and this instance's version may add more in
/// the future — a status the app doesn't recognize yet should degrade gracefully, not
/// corrupt the rest of the snapshot.
nonisolated enum PipelineStatus: Codable, Hashable, Sendable {
    case created
    case waitingForResource
    case preparing
    case pending
    case running
    case success
    case failed
    case canceled
    case skipped
    case manual
    case scheduled
    case unknown(String)

    private var rawValue: String {
        switch self {
        case .created: "created"
        case .waitingForResource: "waiting_for_resource"
        case .preparing: "preparing"
        case .pending: "pending"
        case .running: "running"
        case .success: "success"
        case .failed: "failed"
        case .canceled: "canceled"
        case .skipped: "skipped"
        case .manual: "manual"
        case .scheduled: "scheduled"
        case .unknown(let value): value
        }
    }

    private init(rawValue: String) {
        switch rawValue {
        case "created": self = .created
        case "waiting_for_resource": self = .waitingForResource
        case "preparing": self = .preparing
        case "pending": self = .pending
        case "running": self = .running
        case "success": self = .success
        case "failed": self = .failed
        case "canceled": self = .canceled
        case "skipped": self = .skipped
        case "manual": self = .manual
        case "scheduled": self = .scheduled
        default: self = .unknown(rawValue)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self.init(rawValue: rawValue)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// The 4 display buckets from PLAN.md's menu bar popup table (Pipeline column):
    /// running/pending, success, failed, or none/canceled. Pure data → bucket mapping,
    /// no SF Symbols or colors here — that's MRT-054's job.
    enum DisplayBucket: Sendable, Hashable {
        case runningOrPending
        case success
        case failed
        case noneOrCanceled
    }

    var displayBucket: DisplayBucket {
        switch self {
        case .created, .waitingForResource, .preparing, .pending, .running, .scheduled:
            .runningOrPending
        case .success:
            .success
        case .failed:
            .failed
        case .canceled, .skipped, .manual, .unknown:
            .noneOrCanceled
        }
    }
}
