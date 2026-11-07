import XCTest
@testable import PixoraCore

final class ViewerZoomTests: XCTestCase {
    private let image = CGSize(width: 800, height: 600)
    private let viewport = CGSize(width: 1000, height: 700)

    func testZoomKeepsThePointUnderThePointerStill() {
        var z = ViewerZoom()
        let p = CGPoint(x: 120, y: -80)
        z.zoom(to: 3, around: p, image: image, viewport: viewport)
        // The photo point that was at p (p itself at scale 1, no offset) must still draw at p.
        XCTAssertEqual(p.x * z.scale + z.offset.width, p.x, accuracy: 0.001)
        XCTAssertEqual(p.y * z.scale + z.offset.height, p.y, accuracy: 0.001)
    }

    func testScaleStaysBetweenFitAndMaximum() {
        var z = ViewerZoom()
        z.zoom(to: 100, around: .zero, image: image, viewport: viewport)
        XCTAssertEqual(z.scale, ViewerZoom.maxScale)
        z.zoom(to: 0.2, around: .zero, image: image, viewport: viewport)
        XCTAssertEqual(z.scale, 1)
        XCTAssertFalse(z.isZoomed)
        XCTAssertEqual(z.offset, .zero)
    }

    func testPanStopsAtThePhotoEdges() {
        var z = ViewerZoom()
        z.zoom(to: 2, around: .zero, image: image, viewport: viewport)
        z.pan(by: CGSize(width: 5000, height: -5000), image: image, viewport: viewport)
        XCTAssertEqual(z.offset.width, 300)    // (800×2 − 1000) ÷ 2
        XCTAssertEqual(z.offset.height, -250)  // (600×2 − 700) ÷ 2
    }

    func testAPhotoSmallerThanTheViewportCannotBeDragged() {
        var z = ViewerZoom()
        z.zoom(to: 1.1, around: CGPoint(x: 300, y: 200), image: image, viewport: viewport)
        z.pan(by: CGSize(width: 50, height: 50), image: image, viewport: viewport)
        XCTAssertEqual(z.offset, .zero)
    }

    func testZoomingBackOutRecentresThePhoto() {
        var z = ViewerZoom()
        z.zoom(to: 4, around: CGPoint(x: 300, y: 200), image: image, viewport: viewport)
        XCTAssertNotEqual(z.offset, .zero)
        z.zoom(to: 1, around: CGPoint(x: -100, y: 0), image: image, viewport: viewport)
        XCTAssertEqual(z.offset, .zero)
    }
}
