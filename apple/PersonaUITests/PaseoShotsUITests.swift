import XCTest

/// Throwaway (artifacts branches only, never in a PR): By Repository on the mock hub's Paseo computer (MOCK_PASEO=1 on
/// PERSONA_SHOTS_HUB), the Paseo project's trees and its lead agent, then its first Subtasks row opened. The screens go
/// to PERSONA_SHOTS, named with PERSONA_SHOTS_SUFFIX (the simulator's appearance, switched with simctl ui).
final class PaseoShotsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor func testByRepositoryShots() throws {
        let env = ProcessInfo.processInfo.environment
        guard let hub = env["PERSONA_SHOTS_HUB"] else { throw XCTSkip("needs PERSONA_SHOTS_HUB") }
        let suffix = env["PERSONA_SHOTS_SUFFIX"].map { "-" + $0 } ?? ""
        _ = try? Data(contentsOf: URL(string: hub + "/mock/reset")!)
        let app = XCUIApplication()
        let pair = "persona://pair?url=" + hub.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! + "&token=mock"
        app.launchArguments = ["-pairURL", pair, "-ui.oldLayout", "NO", "-app.tab", "chats", "-tab", "dev", "-dev.openChat", "",
                               "-openAgentsFresh", "YES", "-dev.grouping", "repo", "-dev.machineFilter", "server"]
        app.launchPinned()
        dismissAlerts()
        let all = app.buttons["agents.filter.all"]
        XCTAssertTrue(all.waitForExistence(timeout: 60), "no Agents list")
        sleep(5)
        shot(app, "agents-top" + suffix)
        let lead = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'agents.row' AND label CONTAINS %@", "Rework the login flow")).firstMatch
        bringUp(lead, in: app, column: all)
        sleep(1)
        shot(app, "paseo-folded" + suffix)
        let subtasks = app.buttons.matching(identifier: "agents.subtasks").firstMatch
        bringUp(subtasks, in: app, column: all)
        if subtasks.exists {
            if subtasks.isHittable { subtasks.tap() } else { subtasks.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
            sleep(2)
            shot(app, "paseo-opened" + suffix)
        } else {
            XCTFail("no Subtasks row")
        }
        // The same list under By Status: its sections' counts.
        app.terminate()
        app.launchArguments = ["-pairURL", pair, "-ui.oldLayout", "NO", "-app.tab", "chats", "-tab", "dev", "-dev.openChat", "",
                               "-openAgentsFresh", "YES", "-dev.grouping", "state", "-dev.machineFilter", "server"]
        app.launchPinned()
        dismissAlerts()
        XCTAssertTrue(app.buttons["agents.filter.all"].waitForExistence(timeout: 60), "no Agents list")
        sleep(5)
        shot(app, "by-status" + suffix)
    }

    /// Lifts an element into the upper part of the window with short, slow drags in the list's column.
    @MainActor private func bringUp(_ element: XCUIElement, in app: XCUIApplication, column: XCUIElement, tries: Int = 20) {
        let window = app.windows.firstMatch
        let from = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: column.frame.midX - window.frame.minX, dy: window.frame.height * 0.7))
        for _ in 0..<tries where !(element.exists && element.isHittable && element.frame.minY < window.frame.maxY * 0.6) {
            from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -200)), withVelocity: .slow, thenHoldForDuration: 0.3)
        }
    }

    @MainActor private func dismissAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<2 {
            let ok = springboard.alerts.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "允许", "OK", "好"])).firstMatch
            if ok.waitForExistence(timeout: 2) { ok.tap() }
        }
    }

    @MainActor private func shot(_ app: XCUIApplication, _ name: String) {
        let s = app.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        if let dir = ProcessInfo.processInfo.environment["PERSONA_SHOTS"] {
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
    }
}
