//! Arrow C Data/C Stream ABI. Imports always consume the top-level C structs,
//! on success and failure. Exports are independent of registry handle lifetime.

use crate::registry::{self, Entry};
use polars::prelude::*;
use polars_arrow::{
    array::{new_empty_array, Array, StructArray},
    datatypes::{ArrowDataType, Field},
    ffi::{
        export_array_to_c, export_field_to_c, export_iterator, import_array_from_c,
        import_field_from_c, ArrowArray, ArrowArrayStream, ArrowArrayStreamReader, ArrowSchema,
    },
};
use std::{
    ffi::{c_char, c_int, c_void},
    panic::AssertUnwindSafe,
    ptr,
};

const OK: i32 = 0;
const ERROR: i32 = 1;
const PANIC: i32 = 2;

fn flat(dtype: &ArrowDataType) -> bool {
    matches!(
        dtype,
        ArrowDataType::Null
            | ArrowDataType::Boolean
            | ArrowDataType::Int8
            | ArrowDataType::Int16
            | ArrowDataType::Int32
            | ArrowDataType::Int64
            | ArrowDataType::UInt8
            | ArrowDataType::UInt16
            | ArrowDataType::UInt32
            | ArrowDataType::UInt64
            | ArrowDataType::Float16
            | ArrowDataType::Float32
            | ArrowDataType::Float64
            | ArrowDataType::Utf8
            | ArrowDataType::LargeUtf8
            | ArrowDataType::Utf8View
            | ArrowDataType::Binary
            | ArrowDataType::LargeBinary
            | ArrowDataType::BinaryView
            | ArrowDataType::Date32
            | ArrowDataType::Date64
            | ArrowDataType::Time32(_)
            | ArrowDataType::Time64(_)
            | ArrowDataType::Timestamp(_, _)
            | ArrowDataType::Duration(_)
            | ArrowDataType::Decimal(_, _)
    )
}

fn struct_fields(field: &Field) -> std::result::Result<&[Field], ()> {
    match field.dtype() {
        ArrowDataType::Struct(fields)
            if !field.is_nullable && fields.iter().all(|field| flat(field.dtype())) =>
        {
            Ok(fields)
        }
        _ => Err(()),
    }
}

fn exportable_name(field: &Field) -> bool {
    !field.name.as_bytes().contains(&0)
}

fn frame_array(mut frame: DataFrame) -> std::result::Result<(Box<dyn Array>, Field), ()> {
    frame.rechunk_mut_par();
    let fields = frame
        .columns()
        .iter()
        .map(|column| column.field().to_arrow(CompatLevel::newest()))
        .collect::<Vec<_>>();
    if fields
        .iter()
        .any(|field| !exportable_name(field) || !flat(field.dtype()))
    {
        return Err(());
    }
    let height = frame.height();
    let arrays = frame.rechunk_into_arrow(CompatLevel::newest());
    let dtype = ArrowDataType::Struct(fields.clone());
    let array = StructArray::try_new(dtype.clone(), height, arrays, None).map_err(|_| ())?;
    Ok((Box::new(array), Field::new("".into(), dtype, false)))
}

fn array_frame(array: Box<dyn Array>, field: &Field) -> std::result::Result<DataFrame, ()> {
    let fields = struct_fields(field)?;
    let struct_array = array.as_any().downcast_ref::<StructArray>().ok_or(())?;
    if struct_array.validity().is_some() || struct_array.values().len() != fields.len() {
        return Err(());
    }
    let columns = fields
        .iter()
        .zip(struct_array.values())
        .map(|(field, array)| {
            Series::from_arrow(field.name.clone(), array.clone())
                .map(Series::into_column)
                .map_err(|_| ())
        })
        .collect::<std::result::Result<Vec<_>, _>>()?;
    DataFrame::new(struct_array.len(), columns).map_err(|_| ())
}

unsafe fn take_array(value: *mut ArrowArray) -> std::result::Result<ArrowArray, ()> {
    if value.is_null() {
        return Err(());
    }
    Ok(unsafe { ptr::replace(value, ArrowArray::empty()) })
}

unsafe fn take_schema(value: *mut ArrowSchema) -> std::result::Result<ArrowSchema, ()> {
    if value.is_null() {
        return Err(());
    }
    Ok(unsafe { ptr::replace(value, ArrowSchema::empty()) })
}

unsafe fn take_stream(value: *mut ArrowArrayStream) -> std::result::Result<ArrowArrayStream, ()> {
    if value.is_null() {
        return Err(());
    }
    Ok(unsafe { ptr::replace(value, ArrowArrayStream::empty()) })
}

// polars-arrow keeps these ABI fields private. These local views are used only
// to reject values that 0.55.2 otherwise casts to usize and to adapt an optional
// C Stream callback that its reader incorrectly requires.
#[repr(C)]
struct ArrowArrayView {
    length: i64,
    null_count: i64,
    offset: i64,
    n_buffers: i64,
    n_children: i64,
    buffers: *mut *const c_void,
    children: *mut *mut ArrowArray,
    dictionary: *mut ArrowArray,
    release: Option<unsafe extern "C" fn(*mut ArrowArray)>,
    private_data: *mut c_void,
}

type GetSchema = unsafe extern "C" fn(*mut ArrowArrayStream, *mut ArrowSchema) -> c_int;
type GetNext = unsafe extern "C" fn(*mut ArrowArrayStream, *mut ArrowArray) -> c_int;
type GetLastError = unsafe extern "C" fn(*mut ArrowArrayStream) -> *const c_char;
type ReleaseStream = unsafe extern "C" fn(*mut ArrowArrayStream);

#[repr(C)]
struct ArrowArrayStreamView {
    get_schema: Option<GetSchema>,
    get_next: Option<GetNext>,
    get_last_error: Option<GetLastError>,
    release: Option<ReleaseStream>,
    private_data: *mut c_void,
}

fn array_view(array: &ArrowArray) -> &ArrowArrayView {
    unsafe { &*(array as *const ArrowArray).cast::<ArrowArrayView>() }
}

unsafe fn stream_view_mut(stream: &mut ArrowArrayStream) -> &mut ArrowArrayStreamView {
    unsafe { &mut *(stream as *mut ArrowArrayStream).cast::<ArrowArrayStreamView>() }
}

fn valid_null_count(view: &ArrowArrayView) -> bool {
    view.length >= 0 && view.null_count >= 0 && view.null_count <= view.length
}

fn validate_null_counts(array: &ArrowArray, children: bool) -> std::result::Result<(), ()> {
    let view = array_view(array);
    if !valid_null_count(view) {
        return Err(());
    }
    if !children {
        return Ok(());
    }
    let count = usize::try_from(view.n_children).map_err(|_| ())?;
    if count > 0 && view.children.is_null() {
        return Err(());
    }
    for index in 0..count {
        let child = unsafe { *view.children.add(index) };
        if child.is_null() || !valid_null_count(array_view(unsafe { &*child })) {
            return Err(());
        }
    }
    Ok(())
}

unsafe extern "C" fn no_last_error(_: *mut ArrowArrayStream) -> *const c_char {
    ptr::null()
}

struct ValidatingStream {
    producer: ArrowArrayStream,
    local_error: bool,
}

unsafe fn validating_private(stream: *mut ArrowArrayStream) -> *mut ValidatingStream {
    unsafe {
        stream_view_mut(&mut *stream)
            .private_data
            .cast::<ValidatingStream>()
    }
}

unsafe extern "C" fn validating_get_schema(
    stream: *mut ArrowArrayStream,
    out: *mut ArrowSchema,
) -> c_int {
    if stream.is_null() {
        return 1;
    }
    let private = unsafe { &mut *validating_private(stream) };
    private.local_error = false;
    let callback = unsafe { stream_view_mut(&mut private.producer) }.get_schema;
    match callback {
        Some(callback) => unsafe { callback(&mut private.producer, out) },
        None => {
            private.local_error = true;
            1
        }
    }
}

unsafe extern "C" fn validating_get_next(
    stream: *mut ArrowArrayStream,
    out: *mut ArrowArray,
) -> c_int {
    if stream.is_null() {
        return 1;
    }
    let private = unsafe { &mut *validating_private(stream) };
    private.local_error = false;
    let callback = unsafe { stream_view_mut(&mut private.producer) }.get_next;
    let status = match callback {
        Some(callback) => unsafe { callback(&mut private.producer, out) },
        None => {
            private.local_error = true;
            return 1;
        }
    };
    if status == 0 && !out.is_null() {
        let array = unsafe { &*out };
        // At end-of-stream only a null release callback is authoritative; all
        // other ArrowArray fields are unspecified by the C Stream interface.
        if array_view(array).release.is_some() && validate_null_counts(array, true).is_err() {
            private.local_error = true;
            return 1;
        }
    }
    status
}

unsafe extern "C" fn validating_get_last_error(stream: *mut ArrowArrayStream) -> *const c_char {
    if stream.is_null() {
        return ptr::null();
    }
    let private = unsafe { &mut *validating_private(stream) };
    if private.local_error {
        return ptr::null();
    }
    let callback = unsafe { stream_view_mut(&mut private.producer) }
        .get_last_error
        .unwrap_or(no_last_error);
    unsafe { callback(&mut private.producer) }
}

unsafe extern "C" fn validating_release(stream: *mut ArrowArrayStream) {
    if stream.is_null() {
        return;
    }
    let view = unsafe { stream_view_mut(&mut *stream) };
    let private = view.private_data.cast::<ValidatingStream>();
    view.release = None;
    view.private_data = ptr::null_mut();
    if !private.is_null() {
        unsafe { drop(Box::from_raw(private)) };
    }
}

fn validating_stream(mut producer: ArrowArrayStream) -> ArrowArrayStream {
    let producer_view = unsafe { stream_view_mut(&mut producer) };
    if producer_view.get_last_error.is_none() {
        producer_view.get_last_error = Some(no_last_error);
    }
    let private = Box::new(ValidatingStream {
        producer,
        local_error: false,
    });
    let mut stream = ArrowArrayStream::empty();
    let view = unsafe { stream_view_mut(&mut stream) };
    view.get_schema = Some(validating_get_schema);
    view.get_next = Some(validating_get_next);
    view.get_last_error = Some(validating_get_last_error);
    view.release = Some(validating_release);
    view.private_data = Box::into_raw(private).cast();
    stream
}

#[no_mangle]
pub extern "C" fn df_arrow_array_new() -> *mut ArrowArray {
    std::panic::catch_unwind(|| Box::into_raw(Box::new(ArrowArray::empty())))
        .unwrap_or(ptr::null_mut())
}

#[no_mangle]
pub extern "C" fn df_arrow_schema_new() -> *mut ArrowSchema {
    std::panic::catch_unwind(|| Box::into_raw(Box::new(ArrowSchema::empty())))
        .unwrap_or(ptr::null_mut())
}

#[no_mangle]
pub extern "C" fn df_arrow_stream_new() -> *mut ArrowArrayStream {
    std::panic::catch_unwind(|| Box::into_raw(Box::new(ArrowArrayStream::empty())))
        .unwrap_or(ptr::null_mut())
}

macro_rules! delete {
    ($name:ident, $ty:ty) => {
        #[no_mangle]
        pub unsafe extern "C" fn $name(value: *mut $ty) {
            let _ = std::panic::catch_unwind(AssertUnwindSafe(|| {
                if !value.is_null() {
                    unsafe { drop(Box::from_raw(value)) };
                }
            }));
        }
    };
}
delete!(df_arrow_array_delete, ArrowArray);
delete!(df_arrow_schema_delete, ArrowSchema);
delete!(df_arrow_stream_delete, ArrowArrayStream);

fn boundary(run: impl FnOnce() -> std::result::Result<(), ()>) -> i32 {
    match std::panic::catch_unwind(AssertUnwindSafe(run)) {
        Ok(Ok(())) => OK,
        Ok(Err(())) => ERROR,
        Err(_) => PANIC,
    }
}

#[no_mangle]
pub unsafe extern "C" fn df_series_export_arrow(
    handle: u64,
    out_array: *mut ArrowArray,
    out_schema: *mut ArrowSchema,
) -> i32 {
    boundary(|| {
        if out_array.is_null() || out_schema.is_null() {
            return Err(());
        }
        let series = registry::series(handle).map_err(|_| ())?.rechunk();
        if !flat(&series.dtype().to_arrow(CompatLevel::newest())) {
            return Err(());
        }
        let field = series.field().to_arrow(CompatLevel::newest());
        if !exportable_name(&field) {
            return Err(());
        }
        let array = export_array_to_c(series.to_arrow(0, CompatLevel::newest()));
        let schema = export_field_to_c(&field);
        unsafe {
            ptr::write(out_array, array);
            ptr::write(out_schema, schema);
        }
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn df_frame_export_arrow(
    handle: u64,
    out_array: *mut ArrowArray,
    out_schema: *mut ArrowSchema,
) -> i32 {
    boundary(|| {
        if out_array.is_null() || out_schema.is_null() {
            return Err(());
        }
        let (array, field) = frame_array(registry::frame(handle).map_err(|_| ())?)?;
        let array = export_array_to_c(array);
        let schema = export_field_to_c(&field);
        unsafe {
            ptr::write(out_array, array);
            ptr::write(out_schema, schema);
        }
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn df_series_import_arrow(
    array: *mut ArrowArray,
    schema: *mut ArrowSchema,
    out_handle: *mut u64,
) -> i32 {
    boundary(|| {
        if !out_handle.is_null() {
            unsafe { *out_handle = 0 };
        }
        let array = unsafe { take_array(array)? };
        let schema = unsafe { take_schema(schema)? };
        if out_handle.is_null() {
            return Err(());
        }
        let field = unsafe { import_field_from_c(&schema) }.map_err(|_| ())?;
        if !flat(field.dtype()) {
            return Err(());
        }
        validate_null_counts(&array, false)?;
        let array = unsafe { import_array_from_c(array, field.dtype.clone()) }.map_err(|_| ())?;
        let series = Series::from_arrow(field.name, array).map_err(|_| ())?;
        unsafe { *out_handle = registry::insert(Entry::Series(series)).map_err(|_| ())? };
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn df_frame_import_arrow(
    array: *mut ArrowArray,
    schema: *mut ArrowSchema,
    out_handle: *mut u64,
) -> i32 {
    boundary(|| {
        if !out_handle.is_null() {
            unsafe { *out_handle = 0 };
        }
        let array = unsafe { take_array(array)? };
        let schema = unsafe { take_schema(schema)? };
        if out_handle.is_null() {
            return Err(());
        }
        let field = unsafe { import_field_from_c(&schema) }.map_err(|_| ())?;
        struct_fields(&field)?;
        validate_null_counts(&array, true)?;
        let array = unsafe { import_array_from_c(array, field.dtype.clone()) }.map_err(|_| ())?;
        let frame = array_frame(array, &field)?;
        unsafe { *out_handle = registry::insert(Entry::Frame(frame)).map_err(|_| ())? };
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn df_frame_export_arrow_stream(
    handle: u64,
    max_rows: u64,
    out_stream: *mut ArrowArrayStream,
) -> i32 {
    boundary(|| {
        let rows = usize::try_from(max_rows).map_err(|_| ())?;
        if rows == 0 || out_stream.is_null() {
            return Err(());
        }
        let frame = registry::frame(handle).map_err(|_| ())?;
        let fields = frame
            .columns()
            .iter()
            .map(|column| column.field().to_arrow(CompatLevel::newest()))
            .collect::<Vec<_>>();
        if fields
            .iter()
            .any(|field| !exportable_name(field) || !flat(field.dtype()))
        {
            return Err(());
        }
        let field = Field::new("".into(), ArrowDataType::Struct(fields), false);
        let mut offset = 0usize;
        let iterator = std::iter::from_fn(move || {
            if offset >= frame.height() {
                return None;
            }
            let length = rows.min(frame.height() - offset);
            let array = frame_array(frame.slice(offset as i64, length))
                .map(|value| value.0)
                .map_err(|_| PolarsError::ComputeError("Arrow C stream export failed".into()));
            offset += length;
            Some(array)
        });
        let stream = export_iterator(Box::new(iterator), field);
        unsafe { ptr::write(out_stream, stream) };
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn df_frame_import_arrow_stream(
    stream: *mut ArrowArrayStream,
    max_batches: u64,
    max_rows: u64,
    out_handle: *mut u64,
) -> i32 {
    boundary(|| {
        if !out_handle.is_null() {
            unsafe { *out_handle = 0 };
        }
        let stream = validating_stream(unsafe { take_stream(stream)? });
        if max_batches == 0 || max_rows == 0 || out_handle.is_null() {
            return Err(());
        }
        let mut reader =
            unsafe { ArrowArrayStreamReader::try_new(Box::new(stream)) }.map_err(|_| ())?;
        let field = reader.field().clone();
        let fields = struct_fields(&field)?.to_vec();
        let mut frame: Option<DataFrame> = None;
        let mut batches = 0u64;
        let mut rows = 0u64;
        while let Some(array) = unsafe { reader.next() } {
            batches = batches.checked_add(1).ok_or(())?;
            if batches > max_batches {
                return Err(());
            }
            let batch = array_frame(array.map_err(|_| ())?, &field)?;
            rows = rows.checked_add(batch.height() as u64).ok_or(())?;
            if rows > max_rows {
                return Err(());
            }
            if let Some(output) = &mut frame {
                output.vstack_mut(&batch).map_err(|_| ())?;
            } else {
                frame = Some(batch);
            }
        }
        let frame = match frame {
            Some(frame) => frame,
            None => {
                let columns = fields
                    .into_iter()
                    .map(|field| {
                        Series::from_arrow(field.name, new_empty_array(field.dtype))
                            .map(Series::into_column)
                            .map_err(|_| ())
                    })
                    .collect::<std::result::Result<Vec<_>, _>>()?;
                DataFrame::new(0, columns).map_err(|_| ())?
            }
        };
        unsafe { *out_handle = registry::insert(Entry::Frame(frame)).map_err(|_| ())? };
        Ok(())
    })
}
