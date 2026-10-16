@testable import AgentIntegrations
import XCTest

final class HostApplicationTests: XCTestCase {
    func testOutermostBundleOfHelper() {
        XCTAssertEqual(
            HostApplication.bundlePath(containing: "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper"),
            "/Applications/Claude.app")
        XCTAssertEqual(
            HostApplication.bundlePath(containing: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
            "/System/Applications/Utilities/Terminal.app")
    }

    func testExecutablesOutsideBundles() {
        XCTAssertNil(HostApplication.bundlePath(containing: "/bin/zsh"))
        XCTAssertNil(HostApplication.bundlePath(containing: "/Users/me/.local/bin/claude"))
        XCTAssertNil(HostApplication.bundlePath(containing: "/usr/local/bin/tool.app"), "the executable itself is never the bundle")
        XCTAssertNil(HostApplication.bundlePath(containing: "relative/Foo.app/x"))
        XCTAssertNil(HostApplication.bundlePath(containing: "/opt/.app/bin/x"))
    }

    func testNearestAncestorInsideAnApplicationWins() {
        let ancestry = [
            "/Users/me/Library/Application Support/Claude/claude-code/2.1.0/claude",
            "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper",
            "/Applications/Claude.app/Contents/MacOS/Claude",
            "/sbin/launchd",
        ]
        XCTAssertEqual(HostApplication.bundlePath(inAncestry: ancestry), "/Applications/Claude.app")
        XCTAssertEqual(
            HostApplication.bundlePath(inAncestry: ["/bin/zsh", "/usr/bin/login", "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"]),
            "/System/Applications/Utilities/Terminal.app")
        XCTAssertNil(HostApplication.bundlePath(inAncestry: ["/bin/zsh", "/usr/sbin/sshd"]))
    }
}
