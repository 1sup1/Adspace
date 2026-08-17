import XCTest
@testable import AdaptiveSpace

final class NeedleRuntimeTests: XCTestCase {
    func testToolSchemasEncodeAsStableNeedleJSON() throws {
        let schema = NeedleToolSchema(
            name: "set_lights",
            description: "Set room brightness",
            parameters: [
                "type": .string("object"),
                "properties": .object([
                    "brightness": .object([
                        "type": .string("integer"),
                        "minimum": .integer(0),
                        "maximum": .integer(100)
                    ])
                ]),
                "required": .array([.string("brightness")])
            ]
        )

        let json = try NeedleWireCodec.encodeTools([schema])

        XCTAssertEqual(
            json,
            #"[{"description":"Set room brightness","name":"set_lights","parameters":{"properties":{"brightness":{"maximum":100,"minimum":0,"type":"integer"}},"required":["brightness"],"type":"object"}}]"#
        )
    }

    func testCompletionDecodingPreservesConfidenceAndArguments() throws {
        let data = Data(
            #"{"type":"call","success":true,"function_calls":[{"name":"set_lights","arguments":{"brightness":30,"on":true}}],"reasoning":"dim -> 30","confidence":0.94,"prefill_tps":4300.0,"decode_tps":850.0,"peak_ram_mb":28.0}"#.utf8
        )

        let envelope = try NeedleWireCodec.decodeCompletion(Array(data))

        XCTAssertEqual(envelope.type, "call")
        XCTAssertEqual(envelope.confidence, 0.94)
        XCTAssertEqual(envelope.functionCalls.first?.name, "set_lights")
        XCTAssertEqual(envelope.functionCalls.first?.arguments["brightness"], .integer(30))
        XCTAssertEqual(envelope.functionCalls.first?.arguments["on"], .bool(true))
        XCTAssertEqual(envelope.peakRAMMegabytes, 28.0)
    }

    func testCompletionDecodingRejectsInvalidUTF8() {
        XCTAssertThrowsError(try NeedleWireCodec.decodeCompletion([0x7B, 0xFF, 0x7D])) { error in
            XCTAssertEqual(error as? NeedleRuntimeError, .invalidUTF8)
        }
    }

    func testCompletionDecodingRejectsMalformedJSON() {
        XCTAssertThrowsError(try NeedleWireCodec.decodeCompletion(Array(#"{"type":"call""#.utf8))) { error in
            guard case .invalidJSON = error as? NeedleRuntimeError else {
                return XCTFail("Expected invalidJSON, got \(error)")
            }
        }
    }

    func testNativeDefaultsLeaveRoomForKoreanResponses() {
        XCTAssertEqual(NeedleRuntime.minimumMaxNewTokens, 128)
        XCTAssertGreaterThanOrEqual(NeedleRuntime.outputBufferCapacity, 64 * 1_024)
    }

    func testEmbeddedNativeModelCompletesOnSupportedOS() async throws {
        let runtime = NeedleRuntime.shared
        guard await runtime.availability() == .available else {
            throw XCTSkip("Pinned Needle archive requires iOS 26.5 or newer")
        }
        try await runtime.configure(
            toolSchemas: NeedleBuiltInToolCatalog.schemas,
            systemFacts: "locale: en-US; device: phone; assistant: Adaptive Space"
        )

        let envelope = try await runtime.complete(
            "Apply the recommended environment at home",
            maxNewTokens: 128
        )

        XCTAssertFalse(envelope.type.isEmpty)
        XCTAssertNotNil(envelope.confidence)
        await runtime.reset()
    }
}
