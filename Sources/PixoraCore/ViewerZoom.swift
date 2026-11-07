import CoreGraphics

/// Zoom and pan of one photo in the viewer. Points are relative to the centre of the viewport, and the photo
/// never leaves it: at any scale the offset is limited so no empty edge can be dragged into view.
public struct ViewerZoom: Equatable, Sendable {
    public static let maxScale: CGFloat = 8
    /// Where a double-click or two-finger double-tap lands.
    public static let toggleScale: CGFloat = 2.5

    public private(set) var scale: CGFloat = 1
    public private(set) var offset: CGSize = .zero

    public init() {}

    public var isZoomed: Bool { scale > 1.001 }

    /// Change scale, keeping the point of the photo under `point` where it is.
    public mutating func zoom(to target: CGFloat, around point: CGPoint, image: CGSize, viewport: CGSize) {
        let next = min(max(target, 1), Self.maxScale)
        let ratio = next / scale
        offset = CGSize(width: point.x - (point.x - offset.width) * ratio,
                        height: point.y - (point.y - offset.height) * ratio)
        scale = next
        clamp(image: image, viewport: viewport)
    }

    public mutating func pan(by delta: CGSize, image: CGSize, viewport: CGSize) {
        offset.width += delta.width
        offset.height += delta.height
        clamp(image: image, viewport: viewport)
    }

    private mutating func clamp(image: CGSize, viewport: CGSize) {
        let x = max(0, (image.width * scale - viewport.width) / 2)
        let y = max(0, (image.height * scale - viewport.height) / 2)
        offset = CGSize(width: min(max(offset.width, -x), x), height: min(max(offset.height, -y), y))
    }
}
