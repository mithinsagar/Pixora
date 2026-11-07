import Foundation
import CoreGraphics

/// A two-finger or click-drag swipe on a photo: which way it's going, how far the photo should follow, and where
/// it ends up when let go. Pure maths, so the feel of it can be tested.
public struct ViewerSwipe: Equatable, Sendable {
    public enum Axis: Sendable { case horizontal, vertical }
    /// The way the photo was thrown.
    public enum Outcome: Equatable, Sendable { case left, right, up, down, none }

    /// How far a swipe travels before it commits to a direction.
    static let axisLock: CGFloat = 6
    /// A flick this fast (points per second) counts, however short it was.
    static let flick: CGFloat = 650

    public private(set) var axis: Axis?
    public private(set) var offset: CGSize = .zero
    public private(set) var velocity: CGSize = .zero
    public var allowLeft = true
    public var allowRight = true
    public var allowVertical = true
    private var raw: CGSize = .zero
    private var lastTime: TimeInterval?

    public init(allowLeft: Bool = true, allowRight: Bool = true, allowVertical: Bool = true) {
        self.allowLeft = allowLeft; self.allowRight = allowRight; self.allowVertical = allowVertical
    }

    public var isActive: Bool { axis != nil }

    public mutating func add(_ delta: CGSize, at time: TimeInterval) {
        raw.width += delta.width
        raw.height += delta.height
        if let last = lastTime, time > last {
            let dt = CGFloat(time - last), mix: CGFloat = 0.35   // smoothed: one jittery event shouldn't decide a swipe
            velocity.width = velocity.width * (1 - mix) + delta.width / dt * mix
            velocity.height = velocity.height * (1 - mix) + delta.height / dt * mix
        }
        lastTime = time
        if axis == nil, max(abs(raw.width), abs(raw.height)) >= Self.axisLock {
            axis = abs(raw.height) > abs(raw.width) && allowVertical ? .vertical : .horizontal
        }
        switch axis {
        case .horizontal:
            let blocked = raw.width < 0 ? !allowLeft : !allowRight
            offset = CGSize(width: blocked ? Self.rubberBand(raw.width) : raw.width, height: 0)
        case .vertical: offset = CGSize(width: 0, height: raw.height)
        case nil: break
        }
    }

    /// Where the swipe lands if it's let go now.
    public func outcome(width: CGFloat, distance: CGFloat = 110) -> Outcome {
        switch axis {
        case .horizontal:
            let far = abs(offset.width) > width * 0.2
            let flicked = abs(velocity.width) > Self.flick && velocity.width * offset.width > 0
            guard far || flicked else { return .none }
            if offset.width < 0 { return allowLeft ? .left : .none }
            return allowRight ? .right : .none
        case .vertical:
            let far = abs(offset.height) > distance
            let flicked = abs(velocity.height) > Self.flick && velocity.height * offset.height > 0
            guard far || flicked else { return .none }
            return offset.height < 0 ? .up : .down
        case nil: return .none
        }
    }

    /// Past the first or last photo the picture still moves, but less and less.
    static func rubberBand(_ x: CGFloat, limit: CGFloat = 90) -> CGFloat {
        let a = abs(x)
        return (x < 0 ? -1 : 1) * limit * (1 - 1 / (a / limit * 0.55 + 1))
    }
}
