/*
 * fieldwork_core.h — C ABI of the portable Fieldwork core (ABI version 1).
 *
 * Exported by FieldworkCore.dll (Windows) built from packages/DrillBridge.
 *
 * Contract
 *  - Only fixed-width primitives, byte buffers and opaque 64-bit session handles
 *    cross the boundary. No Swift objects, strings or collections are exposed.
 *  - Text and structured data are UTF-8 JSON byte buffers (not NUL-terminated).
 *  - Every buffer returned through (out_data, out_length) is owned by the core.
 *    Release it exactly once with fw_buffer_free(data, length). Never free it
 *    with another allocator. A NULL out_data pointer skips the buffer.
 *  - Every function returns an explicit status; on failure the returned buffer
 *    (when requested) holds {"ok":false,"status":N,"error":"..."}. Swift errors
 *    never unwind across the boundary.
 *  - Threading: calls on one session are serialized internally by a lock and
 *    may come from any thread. There are no callbacks in ABI version 1.
 *  - A failed command leaves the session (and any document) unchanged.
 */
#ifndef FIELDWORK_CORE_H
#define FIELDWORK_CORE_H

#include <stdint.h>

#ifdef _WIN32
#define FW_API __declspec(dllimport)
#else
#define FW_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

enum {
    FW_OK = 0,
    FW_ERR_INVALID_ARGUMENT = 1,
    FW_ERR_INVALID_HANDLE = 2,
    FW_ERR_COMMAND_FAILED = 3,
    FW_ERR_DECODE_FAILED = 4,
    FW_ERR_INTERNAL = 5
};

/* Returns the ABI version. Callers must check it before any other call. */
FW_API uint32_t fw_abi_version(void);

/* Creates a new show (one movement, 4/4 counts-only timeline, empty preset). */
FW_API int32_t fw_session_create(const uint8_t *title_utf8, int64_t title_length, uint64_t *out_handle);

/* Opens a .fieldwork document from bytes. The bytes are copied; nothing is written. */
FW_API int32_t fw_session_open(const uint8_t *document, int64_t length, uint64_t *out_handle,
                               uint8_t **out_data, int64_t *out_length);

FW_API void fw_session_destroy(uint64_t handle);

/*
 * Applies one JSON command as one undoable transaction, for example
 *   {"type":"addSection","name":"Trumpet","prefix":"T","count":8}
 *   {"type":"placeLine","set":0,"x0":-10,"y0":0,"x1":10,"y1":0}
 *   {"type":"addSet","after":0,"counts":16}
 *   {"type":"movePerformer","set":1,"performer":"T1","x":2.5,"y":-4}
 *   {"type":"undo"}
 * Coordinates are meters from field center (+x audience right, +y back sideline).
 */
FW_API int32_t fw_dispatch_command(uint64_t handle, const uint8_t *json, int64_t length,
                                   uint8_t **out_data, int64_t *out_length);

/* JSON summary: title, revision, dirty flag, field, performers and sets. */
FW_API int32_t fw_get_snapshot(uint64_t handle, uint8_t **out_data, int64_t *out_length);

/* Evaluated positions at a count position (0 = movement start), as JSON. */
FW_API int32_t fw_evaluate_scene(uint64_t handle, double pulse, uint8_t **out_data, int64_t *out_length);

/* Encodes the session as .fieldwork bytes (ZIP container). */
FW_API int32_t fw_encode_document(uint64_t handle, uint8_t **out_data, int64_t *out_length);

FW_API void fw_buffer_free(uint8_t *data, int64_t length);

#ifdef __cplusplus
}
#endif

#endif /* FIELDWORK_CORE_H */
