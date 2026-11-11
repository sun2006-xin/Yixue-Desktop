#ifndef YIXUE_CT2_RUNTIME_H
#define YIXUE_CT2_RUNTIME_H

#include <stddef.h>

#if defined(_WIN32)
#  if defined(YIXUE_CT2_RUNTIME_BUILD)
#    define YIXUE_CT2_API __declspec(dllexport)
#  else
#    define YIXUE_CT2_API __declspec(dllimport)
#  endif
#else
#  define YIXUE_CT2_API
#endif
#ifdef __cplusplus
extern "C" {
#endif

typedef struct YixueCt2Runtime YixueCt2Runtime;

/* ABI version, independent from the CTranslate2 library version. */
YIXUE_CT2_API int yixue_ct2_runtime_abi_version(void);

/*
 * Opens one verified model directory. The directory must contain the
 * CTranslate2 model plus source.spm and target.spm.
 * Returns NULL on failure and writes an allocated UTF-8 error string.
 */
YIXUE_CT2_API YixueCt2Runtime* yixue_ct2_open(
    const char* model_dir_utf8,
    char** error_utf8);

/*
 * Translates one UTF-8 text. Returns an allocated UTF-8 string on success.
 * Empty input and runtime errors return NULL and populate error_utf8.
 */
YIXUE_CT2_API char* yixue_ct2_translate(
    YixueCt2Runtime* runtime,
    const char* source_utf8,
    char** error_utf8);

YIXUE_CT2_API void yixue_ct2_close(YixueCt2Runtime* runtime);

/* Frees strings returned by this ABI, including error strings. */
YIXUE_CT2_API void yixue_ct2_string_free(char* value);

#ifdef __cplusplus
}
#endif

#endif
