import Foundation
import DrillCore
import DrillDocument

// C ABI for native frontends. This is the only file that uses the underscored
// `@_cdecl` attribute; the contract is documented in include/fieldwork_core.h.
// Rules: fixed-width primitives and opaque handles only; every buffer returned
// to the caller is allocated here and must be released with fw_buffer_free;
// Swift errors never cross the boundary (they become status codes + JSON).

let fwABIVersion: UInt32 = 1

private func emit(_ data: Data, _ outData: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, _ outLength: UnsafeMutablePointer<Int64>?) {
    guard let outData, let outLength else { return }
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(data.count, 1))
    data.copyBytes(to: buffer, count: data.count)
    outData.pointee = buffer
    outLength.pointee = Int64(data.count)
}

private func emitJSON(_ object: [String: Any], _ outData: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, _ outLength: UnsafeMutablePointer<Int64>?) {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    emit(data, outData, outLength)
}

private func failure(_ status: Int32, _ message: String, _ outData: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, _ outLength: UnsafeMutablePointer<Int64>?) -> Int32 {
    emitJSON(["ok": false, "status": Int(status), "error": message], outData, outLength)
    return status
}

private func bytes(_ pointer: UnsafePointer<UInt8>?, _ length: Int64) -> Data? {
    guard length >= 0, length <= 1 << 31 else { return nil }
    if length == 0 { return Data() }
    guard let pointer else { return nil }
    return Data(bytes: pointer, count: Int(length))
}

/// Runs `body` with the session locked, translating thrown errors to statuses.
private func withSession(_ handle: UInt64, _ outData: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, _ outLength: UnsafeMutablePointer<Int64>?,
                         _ body: (BridgeSession) throws -> Data) -> Int32 {
    guard let session = BridgeRegistry.shared.get(handle) else {
        return failure(FWStatus.invalidHandle, "Unknown session handle.", outData, outLength)
    }
    session.lock.lock()
    defer { session.lock.unlock() }
    do {
        emit(try body(session), outData, outLength)
        return FWStatus.ok
    } catch let error as BridgeFailure {
        return failure(error.status, error.message, outData, outLength)
    } catch let error as DrillError {
        return failure(FWStatus.commandFailed, error.message, outData, outLength)
    } catch {
        return failure(FWStatus.commandFailed, "\(error)", outData, outLength)
    }
}

@_cdecl("fw_abi_version")
public func fw_abi_version() -> UInt32 { fwABIVersion }

@_cdecl("fw_session_create")
public func fw_session_create(_ title: UnsafePointer<UInt8>?, _ titleLength: Int64, _ outHandle: UnsafeMutablePointer<UInt64>?) -> Int32 {
    guard let outHandle, let data = bytes(title, titleLength), let text = String(data: data, encoding: .utf8) else { return FWStatus.invalidArgument }
    do {
        let show = try Show.makeNew(title: text.isEmpty ? "Untitled Show" : text)
        outHandle.pointee = BridgeRegistry.shared.insert(try BridgeSession(show: show))
        return FWStatus.ok
    } catch {
        return FWStatus.internalError
    }
}

@_cdecl("fw_session_open")
public func fw_session_open(_ document: UnsafePointer<UInt8>?, _ length: Int64, _ outHandle: UnsafeMutablePointer<UInt64>?,
                            _ outData: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, _ outLength: UnsafeMutablePointer<Int64>?) -> Int32 {
    guard let outHandle, let data = bytes(document, length) else { return failure(FWStatus.invalidArgument, "Missing document bytes.", outData, outLength) }
    do {
        let decoded = try DocumentCodec.decode(data)
        outHandle.pointee = BridgeRegistry.shared.insert(try BridgeSession(show: decoded.show, assets: decoded.assets))
        emitJSON(["ok": true, "readOnly": decoded.readOnlyReason ?? NSNull()], outData, outLength)
        return FWStatus.ok
    } catch {
        return failure(FWStatus.decodeFailed, "\(error)", outData, outLength)
    }
}

@_cdecl("fw_session_destroy")
public func fw_session_destroy(_ handle: UInt64) {
    BridgeRegistry.shared.remove(handle)
}

@_cdecl("fw_dispatch_command")
public func fw_dispatch_command(_ handle: UInt64, _ json: UnsafePointer<UInt8>?, _ length: Int64,
                                _ outData: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, _ outLength: UnsafeMutablePointer<Int64>?) -> Int32 {
    guard let data = bytes(json, length) else { return failure(FWStatus.invalidArgument, "Missing command.", outData, outLength) }
    return withSession(handle, outData, outLength) { session in
        try JSONSerialization.data(withJSONObject: try session.dispatch(data), options: [.sortedKeys])
    }
}

@_cdecl("fw_get_snapshot")
public func fw_get_snapshot(_ handle: UInt64, _ outData: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, _ outLength: UnsafeMutablePointer<Int64>?) -> Int32 {
    withSession(handle, outData, outLength) { try JSONSerialization.data(withJSONObject: try $0.snapshot(), options: [.sortedKeys]) }
}

@_cdecl("fw_evaluate_scene")
public func fw_evaluate_scene(_ handle: UInt64, _ pulse: Double, _ outData: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
                              _ outLength: UnsafeMutablePointer<Int64>?) -> Int32 {
    guard pulse.isFinite else { return failure(FWStatus.invalidArgument, "Count position must be finite.", outData, outLength) }
    return withSession(handle, outData, outLength) { try JSONSerialization.data(withJSONObject: try $0.evaluate(pulse: pulse), options: [.sortedKeys]) }
}

@_cdecl("fw_encode_document")
public func fw_encode_document(_ handle: UInt64, _ outData: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, _ outLength: UnsafeMutablePointer<Int64>?) -> Int32 {
    withSession(handle, outData, outLength) { try $0.encode() }
}

@_cdecl("fw_buffer_free")
public func fw_buffer_free(_ data: UnsafeMutablePointer<UInt8>?, _ length: Int64) {
    data?.deallocate()
}
