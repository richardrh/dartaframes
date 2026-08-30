//! Native ABI coverage. This source is intentionally not run in the normal
//! Dart-only verification job because compiling Polars is prohibitively large.

use dartaframes_polars_ffi::{
    df_arrow_array_delete, df_arrow_array_new, df_arrow_schema_delete, df_arrow_schema_new,
    df_arrow_stream_delete, df_arrow_stream_new, df_buffer_free, df_frame_export_arrow,
    df_frame_export_arrow_stream, df_frame_import_arrow, df_frame_import_arrow_stream,
    df_handle_release, df_invoke, df_series_export_arrow, df_series_import_arrow, DfBuffer,
};
use serde_json::{json, Value};
use std::ffi::{c_char, c_int, c_void};

#[repr(C)]
struct ArrowArrayView {
    length: i64,
    null_count: i64,
    offset: i64,
    n_buffers: i64,
    n_children: i64,
    buffers: *mut *const c_void,
    children: *mut *mut ArrowArrayView,
    dictionary: *mut ArrowArrayView,
    release: Option<unsafe extern "C" fn(*mut ArrowArrayView)>,
    private_data: *mut c_void,
}

#[repr(C)]
struct ArrowStreamView {
    get_schema: Option<unsafe extern "C" fn(*mut c_void, *mut c_void) -> c_int>,
    get_next: Option<unsafe extern "C" fn(*mut c_void, *mut c_void) -> c_int>,
    get_last_error: Option<unsafe extern "C" fn(*mut c_void) -> *const c_char>,
    release: Option<unsafe extern "C" fn(*mut c_void)>,
    private_data: *mut c_void,
}

fn invoke(request: Value) -> Value {
    let bytes = serde_json::to_vec(&request).unwrap();
    let mut output = DfBuffer {
        data: std::ptr::null_mut(),
        length: 0,
        status: 0,
    };
    let status = unsafe { df_invoke(bytes.as_ptr(), bytes.len() as u64, &mut output) };
    assert_eq!(status, 0);
    let response = serde_json::from_slice(unsafe {
        std::slice::from_raw_parts(output.data, output.length as usize)
    })
    .unwrap();
    unsafe { df_buffer_free(&mut output) };
    response
}

fn handle(value: &Value) -> u64 {
    value["handle"].as_str().unwrap().parse().unwrap()
}

#[test]
fn frame_c_data_and_stream_round_trip_own_independent_handles() {
    let source = handle(&invoke(json!({
        "protocol": 2,
        "command": "frameImport",
        "batch": {
            "columns": [{
                "name": "value",
                "dtype": {"kind": "int64"},
                "values": ["1", null, "3"]
            }]
        }
    })));

    let source_series = handle(&invoke(json!({
        "protocol": 2,
        "command": "frameColumn",
        "frame": source.to_string(),
        "name": "value"
    })));
    let series_array = df_arrow_array_new();
    let series_schema = df_arrow_schema_new();
    assert_eq!(
        unsafe { df_series_export_arrow(source_series, series_array, series_schema) },
        0
    );
    let mut imported_series = 0;
    assert_eq!(
        unsafe { df_series_import_arrow(series_array, series_schema, &mut imported_series) },
        0
    );
    unsafe {
        df_arrow_schema_delete(series_schema);
        df_arrow_array_delete(series_array);
    }
    assert_ne!(source_series, imported_series);

    let array = df_arrow_array_new();
    let schema = df_arrow_schema_new();
    assert!(!array.is_null() && !schema.is_null());
    assert_eq!(unsafe { df_frame_export_arrow(source, array, schema) }, 0);
    let mut imported = 0;
    assert_eq!(
        unsafe { df_frame_import_arrow(array, schema, &mut imported) },
        0
    );
    // Import moved both payloads and left the allocated top-level structs empty,
    // so deleting those structs cannot release either payload a second time.
    unsafe {
        df_arrow_schema_delete(schema);
        df_arrow_array_delete(array);
    }
    assert_ne!(source, imported);
    assert_eq!(
        invoke(json!({
            "protocol": 2,
            "command": "frameInfo",
            "frame": imported.to_string()
        }))["height"],
        3
    );

    let stream = df_arrow_stream_new();
    assert!(!stream.is_null());
    assert_eq!(
        unsafe { df_frame_export_arrow_stream(source, 2, stream) },
        0
    );
    let mut streamed = 0;
    assert_eq!(
        unsafe { df_frame_import_arrow_stream(stream, 2, 3, &mut streamed) },
        0
    );
    unsafe { df_arrow_stream_delete(stream) };
    assert_ne!(source, streamed);
    assert_ne!(imported, streamed);
    assert_eq!(
        invoke(json!({
            "protocol": 2,
            "command": "frameInfo",
            "frame": streamed.to_string()
        }))["height"],
        3
    );

    assert_eq!(df_handle_release(source), 0);
    // Exported/imported objects remain valid after the source is released.
    assert_eq!(
        invoke(json!({
            "protocol": 2,
            "command": "frameInfo",
            "frame": imported.to_string()
        }))["height"],
        3
    );
    assert_eq!(df_handle_release(imported), 0);
    assert_eq!(df_handle_release(streamed), 0);
    assert_eq!(df_handle_release(source_series), 0);
    assert_eq!(df_handle_release(imported_series), 0);
}

#[test]
fn stream_import_limits_fail_after_consuming_the_stream() {
    let source = handle(&invoke(json!({
        "protocol": 2,
        "command": "frameImport",
        "batch": {"columns": [{"name": "x", "dtype": {"kind": "int32"}, "values": [1, 2]}]}
    })));
    let stream = df_arrow_stream_new();
    assert_eq!(
        unsafe { df_frame_export_arrow_stream(source, 1, stream) },
        0
    );
    let mut output = 0;
    assert_eq!(
        unsafe { df_frame_import_arrow_stream(stream, 1, 2, &mut output) },
        1
    );
    assert_eq!(output, 0);
    // The failed import still moved and released the producer payload exactly
    // once; only the now-empty top-level allocation remains.
    unsafe { df_arrow_stream_delete(stream) };
    assert_eq!(df_handle_release(source), 0);
}

#[test]
fn exports_reject_nul_names_before_writing_outputs() {
    let name = "bad\0name";
    let source = handle(&invoke(json!({
        "protocol": 2,
        "command": "frameImport",
        "batch": {"columns": [{"name": name, "dtype": {"kind": "int32"}, "values": [1]}]}
    })));
    let series = handle(&invoke(json!({
        "protocol": 2,
        "command": "frameColumn",
        "frame": source.to_string(),
        "name": name
    })));

    let array = df_arrow_array_new();
    let schema = df_arrow_schema_new();
    assert_eq!(unsafe { df_frame_export_arrow(source, array, schema) }, 1);
    assert!(unsafe { &*(array.cast::<ArrowArrayView>()) }
        .release
        .is_none());
    assert_eq!(unsafe { df_series_export_arrow(series, array, schema) }, 1);
    assert!(unsafe { &*(array.cast::<ArrowArrayView>()) }
        .release
        .is_none());

    let stream = df_arrow_stream_new();
    assert_eq!(
        unsafe { df_frame_export_arrow_stream(source, 1, stream) },
        1
    );
    assert!(unsafe { &*(stream.cast::<ArrowStreamView>()) }
        .release
        .is_none());

    unsafe {
        df_arrow_stream_delete(stream);
        df_arrow_schema_delete(schema);
        df_arrow_array_delete(array);
    }
    assert_eq!(df_handle_release(series), 0);
    assert_eq!(df_handle_release(source), 0);
}

#[test]
fn imports_consume_and_reject_invalid_null_counts() {
    let source = handle(&invoke(json!({
        "protocol": 2,
        "command": "frameImport",
        "batch": {"columns": [{"name": "x", "dtype": {"kind": "int32"}, "values": [1, null]}]}
    })));
    let series = handle(&invoke(json!({
        "protocol": 2,
        "command": "frameColumn",
        "frame": source.to_string(),
        "name": "x"
    })));

    let array = df_arrow_array_new();
    let schema = df_arrow_schema_new();
    assert_eq!(unsafe { df_series_export_arrow(series, array, schema) }, 0);
    unsafe { (*array.cast::<ArrowArrayView>()).null_count = -1 };
    let mut output = u64::MAX;
    assert_eq!(
        unsafe { df_series_import_arrow(array, schema, &mut output) },
        1
    );
    assert_eq!(output, 0);
    assert!(unsafe { &*(array.cast::<ArrowArrayView>()) }
        .release
        .is_none());
    unsafe {
        df_arrow_schema_delete(schema);
        df_arrow_array_delete(array);
    }

    let array = df_arrow_array_new();
    let schema = df_arrow_schema_new();
    assert_eq!(unsafe { df_series_export_arrow(series, array, schema) }, 0);
    unsafe { (*array.cast::<ArrowArrayView>()).null_count = -2 };
    assert_eq!(
        unsafe { df_series_import_arrow(array, schema, &mut output) },
        1
    );
    unsafe {
        df_arrow_schema_delete(schema);
        df_arrow_array_delete(array);
    }

    let array = df_arrow_array_new();
    let schema = df_arrow_schema_new();
    assert_eq!(unsafe { df_frame_export_arrow(source, array, schema) }, 0);
    let top = unsafe { &mut *array.cast::<ArrowArrayView>() };
    let child = unsafe { &mut **top.children };
    child.null_count = child.length + 1;
    assert_eq!(
        unsafe { df_frame_import_arrow(array, schema, &mut output) },
        1
    );
    assert_eq!(output, 0);
    assert!(unsafe { &*(array.cast::<ArrowArrayView>()) }
        .release
        .is_none());
    unsafe {
        df_arrow_schema_delete(schema);
        df_arrow_array_delete(array);
    }

    assert_eq!(df_handle_release(series), 0);
    assert_eq!(df_handle_release(source), 0);
}

#[test]
fn stream_import_accepts_an_optional_null_error_callback() {
    let source = handle(&invoke(json!({
        "protocol": 2,
        "command": "frameImport",
        "batch": {"columns": [{"name": "x", "dtype": {"kind": "int32"}, "values": [1]}]}
    })));
    let stream = df_arrow_stream_new();
    assert_eq!(
        unsafe { df_frame_export_arrow_stream(source, 1, stream) },
        0
    );
    unsafe { (*stream.cast::<ArrowStreamView>()).get_last_error = None };

    let mut output = 0;
    assert_eq!(
        unsafe { df_frame_import_arrow_stream(stream, 1, 1, &mut output) },
        0
    );
    assert_ne!(output, 0);
    unsafe { df_arrow_stream_delete(stream) };
    assert_eq!(df_handle_release(output), 0);
    assert_eq!(df_handle_release(source), 0);
}
