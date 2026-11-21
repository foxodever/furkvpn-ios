import XCTest

/// Which sheet a tap on the server card opens, with the white list card in each of its states.
final class TapTests: XCTestCase {
    private var lines: [String] = []

    private func launch(_ status: String, glass: String) -> XCUIApplication {
        let app = XCUIApplication()
        // Another app's VPN shows only while ours is off.
        app.launchArguments = ["-demo", "-demoWhitelist", status, "-demoGlass", glass] + (status == "OTHER_VPN" ? [] : ["-demoConnected"])
        app.launch()
        _ = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Сервер'")).firstMatch.waitForExistence(timeout: 15)
        sleep(2)
        return app
    }

    private func opened(_ app: XCUIApplication) -> String {
        if app.navigationBars["Серверы"].waitForExistence(timeout: 3) { return "SERVERS" }
        if app.navigationBars["Белые списки"].exists { return "WHITELIST" }
        return "NOTHING"
    }

    private func close(_ app: XCUIApplication) {
        let button = app.buttons["Закрыть"].firstMatch
        if button.exists { button.tap() }
        sleep(2)
    }

    func testServerCard() {
        for glass in ["liquid", "flat"] {
            for status in ["ALL_OK", "WHITELIST", "NO_INTERNET", "UNKNOWN", "OTHER_VPN"] {
                let app = launch(status, glass: glass)
                let server = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Сервер'")).firstMatch
                let white = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Белые списки'")).firstMatch
                lines.append("== \(glass) \(status): server \(server.exists ? "\(server.frame)" : "MISSING") [\(server.label)] hittable \(server.isHittable); white \(white.exists ? "\(white.frame)" : "MISSING") [\(white.label)]")
                guard server.exists else { continue }
                for (name, dy) in [("top", 0.15), ("middle", 0.5), ("bottom", 0.85)] {
                    server.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: dy)).tap()
                    lines.append("   tap \(name): \(opened(app))")
                    close(app)
                }
                // After the white list sheet has been opened and closed.
                if white.exists {
                    white.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
                    lines.append("   white card: \(opened(app))")
                    close(app)
                    server.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
                    lines.append("   server after it (button): \(opened(app))")
                    close(app)
                    // Closed by pulling the sheet down, then the server card.
                    white.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
                    _ = opened(app)
                    let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
                    top.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
                    sleep(2)
                    lines.append("   pulled down: white sheet still there \(app.navigationBars["Белые списки"].exists)")
                    server.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
                    lines.append("   server after the pull: \(opened(app))")
                    close(app)
                }
                app.terminate()
            }
        }
        // The report: a failure's message is always in xcodebuild's output.
        XCTFail("\nTAPREPORT\n" + lines.joined(separator: "\n") + "\nTAPREPORT END")
    }
}
