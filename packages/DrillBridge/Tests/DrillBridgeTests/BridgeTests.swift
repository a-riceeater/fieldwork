import XCTest
@testable import FieldworkCore

/// Exercises the exported C functions from Swift with raw pointers, the same
/// way a C or C# caller does.
final class BridgeTests: XCTestCase {
    func call(_ body: (UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, UnsafeMutablePointer<Int64>) -> Int32) -> (Int32, [String: Any]) {
        var data: UnsafeMutablePointer<UInt8>?
        var length: Int64 = 0
        let status = body(&data, &length)
        defer { fw_buffer_free(data, length) }
        guard let data else { return (status, [:]) }
        let object = (try? JSONSerialization.jsonObject(with: Data(bytes: data, count: Int(length)))) as? [String: Any] ?? [:]
        return (status, object)
    }

    func command(_ handle: UInt64, _ json: String) -> (Int32, [String: Any]) {
        let bytes = Array(json.utf8)
        return call { fw_dispatch_command(handle, bytes, Int64(bytes.count), $0, $1) }
    }

    func testCreateMoveEncodeDecodeEvaluate() throws {
        XCTAssertEqual(fw_abi_version(), 1)
        var handle: UInt64 = 0
        let title = Array("Bridge".utf8)
        XCTAssertEqual(fw_session_create(title, Int64(title.count), &handle), 0)
        defer { fw_session_destroy(handle) }

        XCTAssertEqual(command(handle, #"{"type":"addSection","name":"Trumpet","prefix":"T","count":4}"#).0, 0)
        XCTAssertEqual(command(handle, #"{"type":"placeLine","set":0,"x0":-6,"y0":0,"x1":6,"y1":0}"#).0, 0)
        XCTAssertEqual(command(handle, #"{"type":"addSet","after":0,"counts":16}"#).0, 0)
        XCTAssertEqual(command(handle, #"{"type":"movePerformer","set":1,"performer":"T1","x":-6,"y":8}"#).0, 0)

        let mid = call { fw_evaluate_scene(handle, 8, $0, $1) }
        XCTAssertEqual(mid.0, 0)
        let t1 = (mid.1["performers"] as! [[String: Any]]).first { $0["label"] as? String == "T1" }!
        XCTAssertEqual(t1["y"] as! Double, 4, accuracy: 1e-9)

        // Encode → open as a new session → same evaluation.
        var docData: UnsafeMutablePointer<UInt8>?
        var docLength: Int64 = 0
        XCTAssertEqual(fw_encode_document(handle, &docData, &docLength), 0)
        var reopened: UInt64 = 0
        let open = call { fw_session_open(docData, docLength, &reopened, $0, $1) }
        fw_buffer_free(docData, docLength)
        XCTAssertEqual(open.0, 0)
        defer { fw_session_destroy(reopened) }
        let snapshot = call { fw_get_snapshot(reopened, $0, $1) }
        XCTAssertEqual((snapshot.1["performers"] as! [Any]).count, 4)
        XCTAssertEqual((snapshot.1["sets"] as! [[String: Any]])[1]["count"] as! Double, 16)
        let again = call { fw_evaluate_scene(reopened, 8, $0, $1) }
        let t1again = (again.1["performers"] as! [[String: Any]]).first { $0["label"] as? String == "T1" }!
        XCTAssertEqual(t1again["y"] as! Double, 4, accuracy: 1e-9)
    }

    func testErrorsAreStatusesAndLeaveStateUnchanged() {
        var handle: UInt64 = 0
        XCTAssertEqual(fw_session_create(nil, 0, &handle), 0)
        defer { fw_session_destroy(handle) }
        let before = call { fw_get_snapshot(handle, $0, $1) }.1["revision"] as! Int

        let unknown = command(handle, #"{"type":"teleport"}"#)
        XCTAssertEqual(unknown.0, 1)
        XCTAssertEqual(unknown.1["ok"] as? Bool, false)
        XCTAssertEqual(command(handle, "not json").0, 1)
        XCTAssertEqual(command(handle, #"{"type":"movePerformer","performer":"Z9","x":0,"y":0}"#).0, 1)
        XCTAssertEqual(command(handle, #"{"type":"undo"}"#).0, 3)
        XCTAssertEqual(call { fw_get_snapshot(handle, $0, $1) }.1["revision"] as! Int, before)

        XCTAssertEqual(call { fw_get_snapshot(987_654, $0, $1) }.0, 2, "invalid handle")
        let garbage: [UInt8] = [1, 2, 3]
        var other: UInt64 = 0
        XCTAssertEqual(call { fw_session_open(garbage, 3, &other, $0, $1) }.0, 4)
    }
}
