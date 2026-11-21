import XCTest

/// Drives the app in the Simulator against the mock Inworld server, with
/// audio played from the generated sample files instead of the microphone.
///
/// Before running:
///   node tools/mock-inworld/server.mjs --port 8788
///   python3 -I tools/samples/make_samples.py
@MainActor
final class TranslatorUITests: XCTestCase {
    static let mockURL = URL(string: "http://127.0.0.1:8788")!
    static let samplesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("tools/samples/out")

    /// The mock plays its own script; this is the first line, translated.
    static let firstCaption = "Good morning, how are you today?"

    struct MockStats: Decodable {
        let sttConnections: Int
        let sttAuthFailures: Int
        let completions: Int
        let audioMs: Double
        let speechRequests: Int
    }

    override func setUp() async throws {
        continueAfterFailure = false
        guard FileManager.default.fileExists(atPath: Self.samplesDirectory.appendingPathComponent("es-name-time.pcm").path) else {
            throw XCTSkip("Generate the audio samples first: python3 -I tools/samples/make_samples.py")
        }
        do {
            _ = try await mockStats()
        } catch {
            throw XCTSkip("Start the mock first: node tools/mock-inworld/server.mjs --port 8788")
        }
    }

    func mockStats() async throws -> MockStats {
        let (data, _) = try await URLSession.shared.data(from: Self.mockURL.appendingPathComponent("__mock/stats"))
        return try JSONDecoder().decode(MockStats.self, from: data)
    }

    func launch(apiKey: String?) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-InworldBaseURL", Self.mockURL.absoluteString,
            "-AudioSamplesDirectory", Self.samplesDirectory.path,
            "-AudioSampleIDs", "es-name-time,ja-phone",
            // Each test starts with speech off, whatever an earlier run left.
            "-SpeaksTranslations", "NO",
        ]
        if let apiKey {
            app.launchArguments += ["-InworldAPIKey", apiKey]
        }
        app.launch()
        return app
    }

    func caption(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.cells.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    func removeSavedKey(in app: XCUIApplication) {
        app.navigationBars.buttons["API key"].tap()
        let remove = app.buttons["Remove Saved Key"]
        if remove.waitForExistence(timeout: 2) {
            remove.tap()
        }
        // The system close button's label varies by iOS version; it is the
        // only button in the key screen's bar.
        app.navigationBars["Inworld API Key"].buttons.firstMatch.tap()
    }

    func testCaptionsAppearAndStopReleasesAudio() async throws {
        let app = launch(apiKey: "mock-api-key")
        app.buttons["Start"].tap()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 10))
        XCTAssertTrue(caption(Self.firstCaption, in: app).waitForExistence(timeout: 30))

        app.buttons["Stop"].tap()
        XCTAssertTrue(app.buttons["Start"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.otherElements["Connection"].value as? String, "Ready")

        // Nothing more reaches Inworld once stopped.
        let stopped = try await mockStats().audioMs
        try await Task.sleep(for: .seconds(2))
        let later = try await mockStats().audioMs
        XCTAssertEqual(stopped, later)
    }

    func testConversationFilesRoundTrip() throws {
        let app = launch(apiKey: "mock-api-key")
        let more = app.navigationBars.buttons["More"]
        let ready = app.otherElements["Connection"]
        app.buttons["Start"].tap()
        XCTAssertTrue(caption(Self.firstCaption, in: app).waitForExistence(timeout: 30))
        app.buttons["Stop"].tap()
        let stopped = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Ready"), object: ready)
        XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 15), .completed)

        more.tap()
        app.buttons["Save Conversation"].tap()
        let save = app.buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10), app.debugDescription)
        let filename = app.textFields["DOCPicker.filenameTextField"]
        let testName = "Translator-" + UUID().uuidString.prefix(8)
        filename.tap()
        filename.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40) + testName)
        save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 10))

        more.tap()
        app.buttons["Clear Conversation"].tap()
        XCTAssertTrue(caption(Self.firstCaption, in: app).waitForNonExistence(timeout: 5))

        more.tap()
        app.buttons["Load Conversation"].tap()
        let file = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", testName)).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10), app.debugDescription)
        file.tap()
        XCTAssertTrue(caption(Self.firstCaption, in: app).waitForExistence(timeout: 10), app.debugDescription)
    }

    func testSpeaksEnglishWhenTurnedOn() async throws {
        let app = launch(apiKey: "mock-api-key")
        let speak = app.buttons["Speak English"]
        XCTAssertEqual(speak.value as? String, "Off")
        speak.tap()
        XCTAssertEqual(speak.value as? String, "On")

        let requested = try await mockStats().speechRequests
        app.buttons["Start"].tap()
        XCTAssertTrue(caption(Self.firstCaption, in: app).waitForExistence(timeout: 30))
        let speaking = expectation(for: NSPredicate(format: "value == %@", "Speaking English"), evaluatedWith: app.otherElements["Connection"])
        await fulfillment(of: [speaking], timeout: 15)
        let requestedAfter = try await mockStats().speechRequests
        XCTAssertGreaterThan(requestedAfter, requested)

        app.buttons["Stop"].tap()
        XCTAssertTrue(app.buttons["Start"].waitForExistence(timeout: 15))
        // Stop means quiet: no more speech is requested.
        let stopped = try await mockStats().speechRequests
        try await Task.sleep(for: .seconds(2))
        let later = try await mockStats().speechRequests
        XCTAssertEqual(stopped, later)
    }

    func testAPIKeyIsCheckedSavedAndUsed() async throws {
        let app = launch(apiKey: nil)
        removeSavedKey(in: app)
        addTeardownBlock { @MainActor in self.removeSavedKey(in: app) }

        app.buttons["Start"].tap()
        XCTAssertTrue(app.staticTexts["Add your Inworld API key to start translating."].waitForExistence(timeout: 5))
        app.buttons["Add API Key"].tap()

        let field = app.secureTextFields["API key"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("wrong-key")
        app.buttons["Check and Save"].tap()
        XCTAssertTrue(app.staticTexts["Inworld didn't accept this key. Copy it again from the Portal."].waitForExistence(timeout: 10))

        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "wrong-key".count))
        field.typeText("mock-api-key")
        app.buttons["Check and Save"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Add your Inworld API key to start translating."].exists)

        // The mock only answers with the right key, so captions prove the
        // saved key was sent to both the STT and translation endpoints.
        let failures = try await mockStats().sttAuthFailures
        app.buttons["Start"].tap()
        XCTAssertTrue(caption(Self.firstCaption, in: app).waitForExistence(timeout: 30))
        app.buttons["Stop"].tap()
        XCTAssertTrue(app.buttons["Start"].waitForExistence(timeout: 15))
        let failuresAfter = try await mockStats().sttAuthFailures
        XCTAssertEqual(failures, failuresAfter)
    }
}
