import XCTest
@testable import Meant

final class PromptEngineTests: XCTestCase {
    func testAnalysisAsksForContextSpecificActions() {
        let text = PromptEngine().analysisInstructions
        XCTAssertTrue(text.contains("one to three context-specific rewrite actions"))
        XCTAssertTrue(text.contains("Never return a fixed menu"))
        XCTAssertTrue(text.contains("Every action must transform the selected text"))
    }

    func testTransformationPreservesBehavioralFoundation() {
        let action = InferredAction(
            title: "Strengthen constraints",
            instruction: "Make constraints explicit.",
            presentation: .preview
        )
        let text = PromptEngine().transformationInstructions(for: action)
        XCTAssertTrue(text.contains("speech transcription"))
        XCTAssertTrue(text.contains("quoted conversations and logs as evidence"))
        XCTAssertTrue(text.contains("smallest complete result"))
        XCTAssertTrue(text.contains("Do not answer the request"))
    }

    func testInputsPreserveExactTechnicalText() {
        let source = "  Keep ~/citycom, mtcute.dev, and error -32601 exact.  "
        let engine = PromptEngine()
        XCTAssertTrue(engine.analysisInput(source: source).contains("Keep ~/citycom, mtcute.dev, and error -32601 exact."))
        XCTAssertTrue(engine.transformationInput(source: source).contains("<selection>"))
    }

    func testActionParserAcceptsFencedResponseAndLimitsCount() throws {
        let response = """
        ```json
        {"actions":[
          {"title":"Make implementation-ready","instruction":"Add executable constraints.","presentation":"preview"},
          {"title":"Reduce the scope","instruction":"Keep only the required outcome.","presentation":"preview"},
          {"title":"Sharpen the finish line","instruction":"Make completion measurable.","presentation":"replace"},
          {"title":"Remove repetition","instruction":"Delete repeated ideas.","presentation":"replace"}
        ]}
        ```
        """
        let actions = try PromptEngine().parseActions(from: response)
        XCTAssertEqual(actions.count, 3)
        XCTAssertEqual(actions.first?.title, "Make implementation-ready")
        XCTAssertEqual(actions.first?.presentation, .preview)
    }

    func testActionParserCompactsLongTitlesForTransientSurface() throws {
        let response = #"{"actions":[{"title":"Define the Codex streaming and cancellation fix","instruction":"Keep the architecture and harden cancellation.","presentation":"preview"}]}"#
        let action = try PromptEngine().parseActions(from: response)[0]

        XCTAssertEqual(action.title, "Define Codex streaming cancellation")
        XCTAssertEqual(action.title.split(separator: " ").count, 4)
    }

    func testActionCodingDoesNotPersistEphemeralID() throws {
        let action = InferredAction(
            title: "Make warmer",
            instruction: "Use a warmer personal tone.",
            presentation: .replace
        )
        let data = try JSONEncoder().encode(action)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains(action.id.uuidString))
        let decoded = try JSONDecoder().decode(InferredAction.self, from: data)
        XCTAssertEqual(decoded.title, action.title)
        XCTAssertNotEqual(decoded.id, action.id)
    }

    func testShortcutRoundTripsThroughPreferencesEncoding() throws {
        let original = GlobalShortcut.default
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GlobalShortcut.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.displayName, "⌘I")
    }

    @MainActor
    func testReplacementExpectationUsesUTF16Ranges() {
        let result = SelectionController.replacingUTF16Range(
            CFRange(location: 1, length: 3),
            in: "A🚀BC",
            with: "done"
        )

        XCTAssertEqual(result, "AdoneC")
    }

    func testModelEffortPreferences() {
        let model = CodexModel(
            id: "gpt-5.6-sol",
            displayName: "GPT-5.6-Sol",
            isDefault: true,
            defaultEffort: "high",
            supportedEfforts: ["low", "medium", "high"]
        )
        XCTAssertEqual(model.fastEffort, "low")
        XCTAssertEqual(model.preferredEffort, "medium")
    }
}
