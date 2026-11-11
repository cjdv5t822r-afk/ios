import XCTest
@testable import StageCore

/// Port of `WatermarkLayoutTest.kt`.
final class WatermarkLayoutTests: XCTestCase {

    private let w: Float = 1080
    private let h: Float = 1920

    func testKeepsLogoAspectAndRequestedWidth() {
        let r = WatermarkLayout.place(frameWidth: w, frameHeight: h, logoAspect: 2, anchor: .topLeft, widthFraction: 0.30)
        XCTAssertEqual(r.width, 324, accuracy: 0.01)
        XCTAssertEqual(r.height, 162, accuracy: 0.01)
        XCTAssertEqual(r.left, w * WatermarkLayout.sideMargin, accuracy: 0.01)
        XCTAssertEqual(r.top, h * WatermarkLayout.topMargin, accuracy: 0.01)
    }

    func testEveryAnchorStaysInsideTheFrameMargins() {
        for anchor in WatermarkAnchor.allCases {
            for fraction: Float in [0.12, 0.30, 0.60, 5] {
                let r = WatermarkLayout.place(frameWidth: w, frameHeight: h, logoAspect: 2, anchor: anchor, widthFraction: fraction)
                XCTAssertGreaterThanOrEqual(r.left, w * WatermarkLayout.sideMargin - 0.01, "\(anchor) \(fraction) left")
                XCTAssertLessThanOrEqual(r.right, w * (1 - WatermarkLayout.sideMargin) + 0.01, "\(anchor) \(fraction) right")
                XCTAssertGreaterThanOrEqual(r.top, h * WatermarkLayout.topMargin - 0.01, "\(anchor) \(fraction) top")
                XCTAssertLessThanOrEqual(r.bottom, h * (1 - WatermarkLayout.bottomMargin) + 0.01, "\(anchor) \(fraction) bottom")
            }
        }
    }

    func testCentredAnchorsAreCentred() {
        let r = WatermarkLayout.place(frameWidth: w, frameHeight: h, logoAspect: 2, anchor: .bottomCenter, widthFraction: 0.4)
        XCTAssertEqual(r.left + r.width / 2, w / 2, accuracy: 0.01)
        XCTAssertEqual(r.bottom, h * (1 - WatermarkLayout.bottomMargin), accuracy: 0.01)
    }

    func testDegenerateAspectFallsBackToSquare() {
        let r = WatermarkLayout.place(frameWidth: w, frameHeight: h, logoAspect: 0, anchor: .topRight, widthFraction: 0.2)
        XCTAssertEqual(r.width, r.height, accuracy: 0.01)
    }

    func testSameFractionsAtAnyFrameSize() {
        // The preview (stage box in points) and the file (1080 x 1920) must put the logo in the same place.
        let file = WatermarkLayout.place(frameWidth: 1080, frameHeight: 1920, logoAspect: 605.0 / 304.0, anchor: .bottomRight, widthFraction: 0.3)
        let preview = WatermarkLayout.place(frameWidth: 390, frameHeight: 693.33, logoAspect: 605.0 / 304.0, anchor: .bottomRight, widthFraction: 0.3)
        XCTAssertEqual(file.left / 1080, preview.left / 390, accuracy: 1e-4)
        XCTAssertEqual(file.top / 1920, preview.top / 693.33, accuracy: 1e-4)
        XCTAssertEqual(file.width / 1080, preview.width / 390, accuracy: 1e-4)
    }
}
