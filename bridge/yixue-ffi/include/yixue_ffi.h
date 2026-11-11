#ifndef YIXUE_FFI_H
#define YIXUE_FFI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct YixueEngine YixueEngine;

uint32_t yixue_bridge_schema_version(void);

/*
 * Processes a null-terminated UTF-8 JSON command.
 * The returned pointer is Rust-owned and must be released exactly once by
 * yixue_string_free. A null input pointer returns a structured JSON error.
 */
char *yixue_process_json(const char *input);

/* Opens a persistent engine. Returns null on invalid input or database failure. */
YixueEngine *yixue_engine_open(const char *database_path);

/* Processes JSON with a live engine. Release the result with yixue_string_free. */
char *yixue_engine_process_json(YixueEngine *engine, const char *input);

/* Releases an engine exactly once. Null is allowed. */
void yixue_engine_free(YixueEngine *engine);

/* Releases a non-null pointer returned by yixue_process_json. Null is allowed. */
void yixue_string_free(char *value);

#ifdef __cplusplus
}
#endif

#endif
