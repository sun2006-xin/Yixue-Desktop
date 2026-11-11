use std::{
    ffi::{CStr, CString, c_char},
    panic::{AssertUnwindSafe, catch_unwind},
    ptr,
};

use crate::{BRIDGE_SCHEMA_VERSION, BridgeEngine, bridge_error, process_json};

/// Returns the JSON bridge schema version supported by this library.
#[unsafe(no_mangle)]
pub extern "C" fn yixue_bridge_schema_version() -> u32 {
    BRIDGE_SCHEMA_VERSION
}

/// Processes one UTF-8 JSON command.
///
/// The returned string is owned by Rust and must be released exactly once with
/// [`yixue_string_free`]. Null input is accepted and returns a JSON error.
///
/// # Safety
///
/// A non-null `input` must point to a readable, null-terminated byte string for
/// the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn yixue_process_json(input: *const c_char) -> *mut c_char {
    let response = catch_unwind(AssertUnwindSafe(|| {
        if input.is_null() {
            return bridge_error("null_input", "request pointer is null");
        }

        // SAFETY: upheld by this function's caller contract and checked for null above.
        let input = unsafe { CStr::from_ptr(input) };
        match input.to_str() {
            Ok(input) => process_json(input),
            Err(_) => bridge_error("invalid_utf8", "request is not valid UTF-8"),
        }
    }))
    .unwrap_or_else(|_| bridge_error("internal_panic", "bridge operation failed safely"));

    into_c_string(response)
}

/// Opens a persistent engine backed by the UTF-8 database path.
///
/// Returns null if the path is null, invalid UTF-8, or the database cannot open.
/// The returned engine must be released exactly once with [`yixue_engine_free`].
///
/// # Safety
///
/// A non-null `database_path` must point to a readable, null-terminated byte
/// string for the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn yixue_engine_open(database_path: *const c_char) -> *mut BridgeEngine {
    catch_unwind(AssertUnwindSafe(|| {
        if database_path.is_null() {
            return ptr::null_mut();
        }
        // SAFETY: upheld by this function's caller contract and checked for null above.
        let database_path = unsafe { CStr::from_ptr(database_path) };
        let Ok(database_path) = database_path.to_str() else {
            return ptr::null_mut();
        };
        BridgeEngine::open(database_path)
            .map(Box::new)
            .map_or_else(|_| ptr::null_mut(), Box::into_raw)
    }))
    .unwrap_or(ptr::null_mut())
}

/// Processes one command using a persistent engine.
///
/// The returned string must be released with [`yixue_string_free`].
///
/// # Safety
///
/// `engine` must be null or a live pointer from [`yixue_engine_open`]. A
/// non-null `input` must point to a readable, null-terminated byte string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn yixue_engine_process_json(
    engine: *mut BridgeEngine,
    input: *const c_char,
) -> *mut c_char {
    let response = catch_unwind(AssertUnwindSafe(|| {
        if engine.is_null() {
            return bridge_error("null_engine", "engine pointer is null");
        }
        if input.is_null() {
            return bridge_error("null_input", "request pointer is null");
        }
        // SAFETY: both pointer obligations are upheld by the caller and checked for null above.
        let engine = unsafe { &*engine };
        // SAFETY: upheld by this function's caller contract and checked for null above.
        let input = unsafe { CStr::from_ptr(input) };
        match input.to_str() {
            Ok(input) => engine.process_json(input),
            Err(_) => bridge_error("invalid_utf8", "request is not valid UTF-8"),
        }
    }))
    .unwrap_or_else(|_| bridge_error("internal_panic", "bridge operation failed safely"));

    into_c_string(response)
}

/// Releases an engine returned by [`yixue_engine_open`]. Null is accepted.
///
/// # Safety
///
/// A non-null pointer must come from [`yixue_engine_open`], remain allocated,
/// and be passed to this function at most once with no concurrent calls active.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn yixue_engine_free(engine: *mut BridgeEngine) {
    if !engine.is_null() {
        // SAFETY: upheld by this function's caller contract and checked for null above.
        drop(unsafe { Box::from_raw(engine) });
    }
}

/// Releases a string returned by [`yixue_process_json`]. Null is accepted.
///
/// # Safety
///
/// A non-null `value` must have been returned by [`yixue_process_json`], must
/// still be allocated, and must be passed to this function at most once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn yixue_string_free(value: *mut c_char) {
    if !value.is_null() {
        // SAFETY: upheld by this function's caller contract and checked for null above.
        drop(unsafe { CString::from_raw(value) });
    }
}

fn into_c_string(value: String) -> *mut c_char {
    CString::new(value).map_or_else(|_| ptr::null_mut(), CString::into_raw)
}
