import Foundation

/// Quick Pick: go through photos one at a time and decide. Skipping only moves on: nothing is ever removed.
public struct PickSession: Equatable, Sendable {
    public enum Decision: Equatable, Sendable { case skip, keep, favorite }
    public struct Step: Equatable, Sendable {
        public let id: Int64
        public let decision: Decision
        /// It was already a favorite, so undoing must leave the heart on.
        public let wasFavorite: Bool
    }

    public let ids: [Int64]
    public private(set) var history: [Step] = []

    public init(ids: [Int64]) { self.ids = ids }

    public var index: Int { history.count }
    public var current: Int64? { index < ids.count ? ids[index] : nil }
    public var upNext: Int64? { index + 1 < ids.count ? ids[index + 1] : nil }
    public var isFinished: Bool { index >= ids.count }
    public var progress: Double { ids.isEmpty ? 1 : Double(index) / Double(ids.count) }

    public func count(_ d: Decision) -> Int { history.lazy.filter { $0.decision == d }.count }
    public func picked(_ d: Decision) -> [Int64] { history.filter { $0.decision == d }.map(\.id) }
    /// Everything not skipped, in the order it was shown.
    public var kept: [Int64] { history.filter { $0.decision != .skip }.map(\.id) }

    public mutating func decide(_ d: Decision, wasFavorite: Bool = false) {
        guard let id = current else { return }
        history.append(Step(id: id, decision: d, wasFavorite: wasFavorite))
    }

    @discardableResult
    public mutating func undo() -> Step? { history.popLast() }
}
