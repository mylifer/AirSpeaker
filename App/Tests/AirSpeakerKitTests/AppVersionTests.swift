import AirSpeakerKit
import XCTest

final class AppVersionTests: XCTestCase {
    func testParsing() {
        XCTAssertEqual(AppVersion("0.3.1")?.components, [0, 3, 1])
        XCTAssertEqual(AppVersion("v1.2.0")?.components, [1, 2, 0])
        XCTAssertEqual(AppVersion(" V2 ")?.components, [2])
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("1..2"))
        XCTAssertNil(AppVersion("1.2-beta"))
        XCTAssertNil(AppVersion("latest"))
    }

    func testComparison() throws {
        let v031 = try XCTUnwrap(AppVersion("0.3.1"))
        let v040 = try XCTUnwrap(AppVersion("v0.4.0"))
        let v0310 = try XCTUnwrap(AppVersion("0.3.10"))
        XCTAssertLessThan(v031, v040)
        XCTAssertLessThan(v031, v0310, "sayısal karşılaştırılmalı, metin olarak değil")
        XCTAssertEqual(AppVersion("1.2"), AppVersion("1.2.0"))
        XCTAssertFalse(v040 < v040)
        XCTAssertGreaterThan(v040, v0310)
    }

    func testDescription() {
        XCTAssertEqual(AppVersion("v0.4.0")?.description, "0.4.0")
    }
}
