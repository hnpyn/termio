import XCTest
@testable import termio

/// The link another Mac pastes, and the host key a paired Mac is filed under.
final class PairedDeviceTests: XCTestCase {
    private let link = "termio://device?url=http://100.74.228.124:8795&token=s3cret&host_id=h_abc&proto=1&name=Studio"

    func testALinkFromThePairingSheetParses() throws {
        let device = try XCTUnwrap(PairedDevice(link: link))
        XCTAssertEqual(device.hostID, "h_abc")
        XCTAssertEqual(device.token, "s3cret")
        XCTAssertEqual(device.name, "Studio")
        XCTAssertEqual(device.websocketURL?.absoluteString, "ws://100.74.228.124:8795/ws")
    }

    func testALinkWithoutANameIsNamedByItsHost() throws {
        let device = try XCTUnwrap(PairedDevice(
            link: "termio://device?url=https://mini.tail1.ts.net/termio&token=t&host_id=h"))
        XCTAssertEqual(device.name, "mini.tail1.ts.net")
        XCTAssertEqual(device.websocketURL?.absoluteString, "wss://mini.tail1.ts.net/termio/ws")
    }

    func testALinkMissingWhatTheDialNeedsIsRefused() {
        XCTAssertNil(PairedDevice(link: "termio://device?url=http://h:1&host_id=h"))
        XCTAssertNil(PairedDevice(link: "termio://device?token=t&host_id=h"))
        XCTAssertNil(PairedDevice(link: "termio://device?url=ftp://h:1&token=t&host_id=h"))
        XCTAssertNil(PairedDevice(link: "https://example.com/?url=http://h:1&token=t&host_id=h"))
    }

    func testAPairedMacIsNeverFiledAsThisMac() {
        // The app's state keys machines by one string, nil for this Mac. A paired
        // Mac must come back as itself, not as the local route.
        let route = TermiodRoute.paired("h_abc")
        XCTAssertEqual(route.hostKey, "paired:h_abc")
        XCTAssertEqual(TermiodRoute(hostKey: route.hostKey), route)
        XCTAssertNil(route.sshAlias, "nothing may run ssh against a paired Mac")
        XCTAssertEqual(TermiodRoute(hostKey: "vps"), .ssh("vps"))
        XCTAssertEqual(TermiodRoute(hostKey: nil), .local)
    }

    func testAPairedRouteRoundTripsThroughItsSpelling() throws {
        let data = try JSONEncoder().encode([TermiodRoute.paired("h_abc")])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"["paired:h_abc"]"#)
        XCTAssertEqual(try JSONDecoder().decode([TermiodRoute].self, from: data), [.paired("h_abc")])
    }
}
