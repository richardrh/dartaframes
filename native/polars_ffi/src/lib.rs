#![recursion_limit = "256"]

mod advanced_expr;
mod arrow_c;
mod batch;
mod batch_stream;
mod bindings;
mod dtype;
mod eager;
mod engine;
mod error;
mod io_extended;
mod jobs;
mod namespace_expr;
mod registry;
mod selectors;
mod sql;
mod temporal_relational;

use std::{
    ffi::c_void,
    panic::{catch_unwind, AssertUnwindSafe},
    ptr,
};

pub const ABI_VERSION: u32 = 2;
const STATUS_OK: i32 = 0;
const STATUS_ERROR: i32 = 1;
const STATUS_PANIC: i32 = 2;

#[repr(C)]
pub struct DfBuffer {
    pub data: *mut u8,
    pub length: u64,
    pub status: i32,
}

impl DfBuffer {
    fn empty() -> Self {
        Self {
            data: ptr::null_mut(),
            length: 0,
            status: STATUS_OK,
        }
    }
}

unsafe fn set_buffer(out: *mut DfBuffer, bytes: Vec<u8>, status: i32) {
    let boxed = bytes.into_boxed_slice();
    let length = boxed.len() as u64;
    let data = Box::into_raw(boxed) as *mut u8;
    unsafe {
        *out = DfBuffer {
            data,
            length,
            status,
        }
    }
}

fn panic_json() -> Vec<u8> {
    br#"{"ok":false,"error":{"category":"internalError","message":"panic caught at native ABI boundary"}}"#.to_vec()
}

#[no_mangle]
pub extern "C" fn df_abi_version() -> u32 {
    catch_unwind(|| ABI_VERSION).unwrap_or(0)
}

/// Invoke the JSON protocol.
///
/// # Safety
/// `result` must be non-null, aligned, and writable for one `DfBuffer`. When
/// `request_length` is non-zero, `request` must point to that many initialized
/// bytes. The regions must not overlap.
#[no_mangle]
pub unsafe extern "C" fn df_invoke(
    request: *const u8,
    request_length: u64,
    result: *mut DfBuffer,
) -> i32 {
    if result.is_null() {
        return STATUS_ERROR;
    }
    let run = catch_unwind(AssertUnwindSafe(|| {
        unsafe { *result = DfBuffer::empty() };
        if request.is_null() && request_length != 0 {
            let error = error::EngineError::Invalid("null request pointer".into());
            let bytes = serde_json::to_vec(&error.envelope()).unwrap_or_else(|_| panic_json());
            unsafe { set_buffer(result, bytes, STATUS_ERROR) };
            return STATUS_ERROR;
        }
        if request_length > usize::MAX as u64 {
            let error =
                error::EngineError::Invalid("request length does not fit this platform".into());
            let bytes = serde_json::to_vec(&error.envelope()).unwrap_or_else(|_| panic_json());
            unsafe { set_buffer(result, bytes, STATUS_ERROR) };
            return STATUS_ERROR;
        }
        let bytes = if request_length == 0 {
            &[]
        } else {
            unsafe { std::slice::from_raw_parts(request, request_length as usize) }
        };
        match engine::invoke(bytes) {
            Ok(value) => {
                let bytes = serde_json::to_vec(&value).unwrap_or_else(|_| panic_json());
                unsafe { set_buffer(result, bytes, STATUS_OK) };
                STATUS_OK
            }
            Err(error) => {
                let bytes = serde_json::to_vec(&error.envelope()).unwrap_or_else(|_| panic_json());
                unsafe { set_buffer(result, bytes, STATUS_ERROR) };
                STATUS_ERROR
            }
        }
    }));
    match run {
        Ok(status) => status,
        Err(_) => catch_unwind(AssertUnwindSafe(|| unsafe {
            *result = DfBuffer::empty();
            set_buffer(result, panic_json(), STATUS_PANIC);
            STATUS_PANIC
        }))
        .unwrap_or(STATUS_PANIC),
    }
}

/// Release bytes returned in a `DfBuffer`.
///
/// # Safety
/// `buffer` must be null or point to a live, writable `DfBuffer` produced by
/// `df_invoke` that has not already been freed or modified.
#[no_mangle]
pub unsafe extern "C" fn df_buffer_free(buffer: *mut DfBuffer) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if buffer.is_null() {
            return;
        }
        let buffer = unsafe { &mut *buffer };
        if !buffer.data.is_null() {
            if buffer.length > usize::MAX as u64 {
                *buffer = DfBuffer::empty();
                return;
            }
            let slice = ptr::slice_from_raw_parts_mut(buffer.data, buffer.length as usize);
            unsafe { drop(Box::from_raw(slice)) }
        }
        *buffer = DfBuffer::empty();
    }));
}

#[no_mangle]
pub extern "C" fn df_handle_release(handle: u64) -> i32 {
    match catch_unwind(AssertUnwindSafe(|| registry::release(handle))) {
        Ok(Ok(())) => STATUS_OK,
        _ => STATUS_ERROR,
    }
}

#[repr(C)]
struct HandleToken {
    handle: u64,
}

#[no_mangle]
pub extern "C" fn df_handle_token_new(handle: u64) -> *mut c_void {
    catch_unwind(AssertUnwindSafe(|| {
        Box::into_raw(Box::new(HandleToken { handle })) as *mut c_void
    }))
    .unwrap_or(ptr::null_mut())
}

pub use arrow_c::{
    df_arrow_array_delete, df_arrow_array_new, df_arrow_schema_delete, df_arrow_schema_new,
    df_arrow_stream_delete, df_arrow_stream_new, df_frame_export_arrow,
    df_frame_export_arrow_stream, df_frame_import_arrow, df_frame_import_arrow_stream,
    df_series_export_arrow, df_series_import_arrow,
};

/// NativeFinalizer callback with C type `void (*)(void *)`.
///
/// # Safety
/// `token` must be null or a pointer returned by `df_handle_token_new`, passed
/// at most once.
#[no_mangle]
pub unsafe extern "C" fn df_handle_token_release(token: *mut c_void) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if token.is_null() {
            return;
        }
        let token = unsafe { Box::from_raw(token as *mut HandleToken) };
        let _ = registry::release(token.handle);
    }));
}

#[cfg(test)]
mod abi_tests {
    use super::*;
    use crate::registry::{self, Entry};
    use polars::prelude::*;
    use serde_json::Value;

    unsafe fn invoke_raw(request: &[u8]) -> (i32, DfBuffer, Value) {
        let mut buffer = DfBuffer::empty();
        let status = unsafe { df_invoke(request.as_ptr(), request.len() as u64, &mut buffer) };
        assert!(!buffer.data.is_null());
        assert!(buffer.length > 0);
        let value = serde_json::from_slice(unsafe {
            std::slice::from_raw_parts(buffer.data, buffer.length as usize)
        })
        .unwrap();
        (status, buffer, value)
    }

    #[test]
    fn malformed_requests_return_owned_error_buffers() {
        let expression = registry::insert(Entry::Expr(lit(1_i32))).unwrap();
        let requests = [
            b"{".to_vec(),
            b"".to_vec(),
            br#"{"protocol":1,"command":"hello"}"#.to_vec(),
            br#"{"protocol":2,"command":"hello","extra":true}"#.to_vec(),
            br#"{"protocol":2,"command":"frameInfo","frame":1}"#.to_vec(),
            format!(r#"{{"protocol":2,"command":"exprAggregate","input":"{expression}","op":"sum","ddof":1}}"#).into_bytes(),
            format!(r#"{{"protocol":2,"command":"exprFunction","input":"{expression}","name":"round","arguments":[],"decimals":0}}"#).into_bytes(),
        ];
        for request in requests {
            let (status, mut buffer, response) = unsafe { invoke_raw(&request) };
            assert_eq!(status, STATUS_ERROR, "{response}");
            assert_eq!(buffer.status, STATUS_ERROR);
            assert_eq!(response["ok"], false);
            unsafe { df_buffer_free(&mut buffer) };
            assert!(buffer.data.is_null());
            assert_eq!(buffer.length, 0);
            assert_eq!(buffer.status, STATUS_OK);
        }
        registry::release(expression).unwrap();
        unsafe { df_buffer_free(ptr::null_mut()) };
        assert_eq!(
            unsafe { df_invoke(ptr::null(), 0, ptr::null_mut()) },
            STATUS_ERROR
        );
    }
}
