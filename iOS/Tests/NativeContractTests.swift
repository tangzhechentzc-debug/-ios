import XCTest
@testable import ChangeLocationiOS

final class NativeContractTests: XCTestCase {
    func testSwiftRequestPreservesNativeRecoveryField() throws {
        var request = EngineRequest(op: "connect")
        request.pairingRecord = "opaque-test-record"
        request.recoveryNeeded = true
        request.authTag = "test-tag"
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(request)) as? [String: Any])
        XCTAssertEqual(json["recovery_needed"] as? Bool, true)
        XCTAssertEqual(json["pairing_record"] as? String, "opaque-test-record")
        XCTAssertEqual(json["auth_tag"] as? String, "test-tag")
    }

    func testPairingReplyDecodesCodeAndRecord() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let reply = try decoder.decode(EngineReply.self, from: Data(
            #"{"ok":true,"state":"idle","pairing_state":"code","pairing_code":"123456"}"#.utf8))
        XCTAssertEqual(reply.pairingState, "code")
        XCTAssertEqual(reply.pairingCode, "123456")
        XCTAssertNil(reply.pairingRecord)
    }

    func testNativeRejectsInvalidPositionWithoutNetwork() async throws {
        var request = EngineRequest(op: "apply")
        request.latitude = 91
        request.longitude = 0
        do {
            _ = try await NativeEngine().send(request)
            XCTFail("Invalid coordinate must not reach a device")
        } catch {
            XCTAssertTrue(error is LocationFailure)
        }
    }
}
