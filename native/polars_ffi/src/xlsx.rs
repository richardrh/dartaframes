use std::{collections::HashSet, path::Path};

use calamine::{open_workbook, Data as CellData, Reader, Xlsx};
use chrono::{DateTime, Duration, NaiveDate, NaiveDateTime, NaiveTime, Utc};
use polars::prelude::*;
use rust_xlsxwriter::{Format, Workbook, Worksheet};
use serde_json::{json, Value};
use tempfile::NamedTempFile;

use crate::{
    bindings as b,
    error::{EngineError, Result},
    registry::{self, Entry},
};

const DEFAULT_WORKSHEET: &str = "Sheet1";
const DEFAULT_INFER_ROWS: usize = 100;
const MAX_EXCEL_ROWS: usize = 1_048_576;
const MAX_EXCEL_COLUMNS: usize = 16_384;
const MAX_EXACT_EXCEL_INTEGER: i128 = 9_007_199_254_740_992;

pub fn dispatch(command: &str, request: &Value) -> Result<Option<Value>> {
    let payload = match command {
        "frameReadExcel" => {
            fields(
                request,
                &[
                    "path",
                    "worksheet",
                    "hasHeader",
                    "columnNames",
                    "inferSchemaLength",
                ],
            )?;
            let frame = read_excel(request)?;
            let handle = registry::insert(Entry::Frame(frame))?;
            json!({"handle": handle.to_string(), "kind": "frame"})
        }
        "frameWriteExcel" => {
            fields(
                request,
                &[
                    "frame",
                    "path",
                    "worksheet",
                    "includeHeader",
                    "dateFormat",
                    "datetimeFormat",
                ],
            )?;
            write_excel(request)?
        }
        _ => return Ok(None),
    };
    Ok(Some(payload))
}

fn fields(value: &Value, extra: &[&str]) -> Result<()> {
    let mut allowed = vec!["protocol", "command"];
    allowed.extend(extra);
    b::validate_fields(value, &allowed)
}

fn local_path(value: &Value) -> Result<&str> {
    let path = b::string(value, "path")?;
    if path.is_empty() || path.len() > 1_048_576 {
        return Err(EngineError::Invalid(
            "'path' must be a non-empty local filesystem path".into(),
        ));
    }
    if path.contains("://") {
        return Err(EngineError::Unsupported(
            "Excel I/O supports only local filesystem paths".into(),
        ));
    }
    Ok(path)
}

fn optional_string<'a>(value: &'a Value, key: &str) -> Result<Option<&'a str>> {
    value
        .get(key)
        .map(|raw| {
            raw.as_str()
                .ok_or_else(|| EngineError::Invalid(format!("'{key}' must be a string")))
        })
        .transpose()
}

fn worksheet_name<'a>(value: &'a Value, default: &'a str) -> Result<&'a str> {
    let name = optional_string(value, "worksheet")?.unwrap_or(default);
    if name.is_empty() {
        return Err(EngineError::Invalid(
            "'worksheet' must be a non-empty string".into(),
        ));
    }
    Ok(name)
}

fn column_names(value: &Value) -> Result<Option<Vec<String>>> {
    let Some(raw) = value.get("columnNames") else {
        return Ok(None);
    };
    let values = raw
        .as_array()
        .ok_or_else(|| EngineError::Invalid("'columnNames' must be an array".into()))?;
    if values.is_empty() || values.len() > MAX_EXCEL_COLUMNS {
        return Err(EngineError::Invalid(format!(
            "'columnNames' must contain between 1 and {MAX_EXCEL_COLUMNS} names"
        )));
    }
    let mut names = Vec::with_capacity(values.len());
    let mut unique = HashSet::with_capacity(values.len());
    for raw in values {
        let name = raw.as_str().ok_or_else(|| {
            EngineError::Invalid("every 'columnNames' value must be a string".into())
        })?;
        if name.is_empty() {
            return Err(EngineError::Invalid(
                "column names must not be empty".into(),
            ));
        }
        if !unique.insert(name.to_owned()) {
            return Err(EngineError::Invalid(format!(
                "duplicate Excel column name '{name}'"
            )));
        }
        names.push(name.to_owned());
    }
    Ok(Some(names))
}

fn infer_schema_length(value: &Value) -> Result<Option<usize>> {
    match value.get("inferSchemaLength") {
        None => Ok(Some(DEFAULT_INFER_ROWS)),
        Some(Value::Null) => Ok(None),
        Some(raw) => {
            let count = raw.as_u64().ok_or_else(|| {
                EngineError::Invalid("'inferSchemaLength' must be positive or null".into())
            })?;
            let count = usize::try_from(count)
                .map_err(|_| EngineError::Invalid("'inferSchemaLength' is too large".into()))?;
            if count == 0 {
                return Err(EngineError::Invalid(
                    "'inferSchemaLength' must be positive or null".into(),
                ));
            }
            Ok(Some(count))
        }
    }
}

fn read_excel(value: &Value) -> Result<DataFrame> {
    let path = local_path(value)?;
    let mut workbook: Xlsx<_> = open_workbook(path)
        .map_err(|error| EngineError::Io(format!("failed to open XLSX workbook: {error}")))?;
    let requested = optional_string(value, "worksheet")?;
    let sheet = match requested {
        Some(name) if name.is_empty() => {
            return Err(EngineError::Invalid(
                "'worksheet' must be a non-empty string".into(),
            ))
        }
        Some(name) => name.to_owned(),
        None => workbook
            .sheet_names()
            .first()
            .cloned()
            .ok_or_else(|| EngineError::Execution("XLSX workbook has no worksheets".into()))?,
    };
    let range = workbook.worksheet_range(&sheet).map_err(|error| {
        EngineError::Execution(format!("failed to read XLSX worksheet '{sheet}': {error}"))
    })?;
    let has_header = b::optional_bool(value, "hasHeader", true)?;
    let supplied_names = column_names(value)?;
    let infer_length = infer_schema_length(value)?;
    let rows = range.rows().map(|row| row.to_vec()).collect::<Vec<_>>();

    let range_width = rows.iter().map(Vec::len).max().unwrap_or(0);
    let names = if let Some(names) = supplied_names {
        if range_width > names.len() {
            return Err(EngineError::Execution(format!(
                "worksheet '{sheet}' has {range_width} columns but columnNames has {}",
                names.len()
            )));
        }
        names
    } else if has_header {
        let header = rows.first().ok_or_else(|| {
            EngineError::Execution(format!(
                "worksheet '{sheet}' is empty and hasHeader is true"
            ))
        })?;
        if header.is_empty() {
            return Err(EngineError::Execution(format!(
                "worksheet '{sheet}' has an empty header row"
            )));
        }
        header
            .iter()
            .enumerate()
            .map(|(index, cell)| header_name(cell, index))
            .collect::<Result<Vec<_>>>()?
    } else {
        if range_width == 0 {
            return Err(EngineError::Execution(format!(
                "worksheet '{sheet}' has no columns; supply columnNames for an empty sheet"
            )));
        }
        (1..=range_width)
            .map(|index| format!("column_{index}"))
            .collect()
    };
    validate_unique_names(&names)?;
    if names.len() > MAX_EXCEL_COLUMNS {
        return Err(EngineError::Execution(format!(
            "worksheet exceeds Excel's {MAX_EXCEL_COLUMNS} column limit"
        )));
    }

    let body_start = usize::from(has_header);
    let body = rows.get(body_start..).unwrap_or_default();
    if body.len() > MAX_EXCEL_ROWS - body_start {
        return Err(EngineError::Execution(format!(
            "worksheet exceeds Excel's {MAX_EXCEL_ROWS} row limit"
        )));
    }
    let scan_rows = infer_length.unwrap_or(body.len()).min(body.len());
    let mut columns = Vec::with_capacity(names.len());
    for (column_index, name) in names.iter().enumerate() {
        let mut inferred = CellKind::Null;
        for row in body.iter().take(scan_rows) {
            inferred = inferred
                .merge(classify(row.get(column_index).unwrap_or(&CellData::Empty))?)
                .map_err(|(left, right)| mixed_column(name, left, right))?;
        }
        columns.push(build_column(
            name,
            column_index,
            body,
            inferred,
            body_start,
        )?);
    }
    DataFrame::new(body.len(), columns.into_iter().map(Into::into).collect()).map_err(Into::into)
}

fn header_name(cell: &CellData, index: usize) -> Result<String> {
    let name = match cell {
        CellData::String(value) => value.clone(),
        CellData::Int(value) => value.to_string(),
        CellData::Float(value) => value.to_string(),
        CellData::Bool(value) => value.to_string(),
        CellData::DateTime(value) if !value.is_duration() => value
            .as_datetime()
            .map(|value| value.to_string())
            .ok_or_else(|| EngineError::Execution("invalid Excel header datetime".into()))?,
        CellData::DateTimeIso(value) => value.clone(),
        CellData::Empty => String::new(),
        CellData::DurationIso(_) => {
            return Err(EngineError::Unsupported(
                "Excel duration header cells are unsupported".into(),
            ))
        }
        CellData::Error(error) => {
            return Err(EngineError::Execution(format!(
                "Excel header cell {} contains error {error}",
                index + 1
            )))
        }
        CellData::DateTime(_) => {
            return Err(EngineError::Unsupported(
                "Excel duration header cells are unsupported".into(),
            ))
        }
    };
    if name.is_empty() {
        return Err(EngineError::Execution(format!(
            "Excel header cell {} is empty; supply columnNames",
            index + 1
        )));
    }
    Ok(name)
}

fn validate_unique_names(names: &[String]) -> Result<()> {
    let mut unique = HashSet::with_capacity(names.len());
    for name in names {
        if name.is_empty() {
            return Err(EngineError::Execution(
                "Excel column names must not be empty".into(),
            ));
        }
        if !unique.insert(name) {
            return Err(EngineError::Execution(format!(
                "duplicate Excel column name '{name}'"
            )));
        }
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CellKind {
    Null,
    Boolean,
    Integer,
    Float,
    String,
    Date,
    Datetime,
}

impl CellKind {
    fn merge(self, other: Self) -> std::result::Result<Self, (Self, Self)> {
        use CellKind::*;
        match (self, other) {
            (Null, value) | (value, Null) => Ok(value),
            (left, right) if left == right => Ok(left),
            (Integer, Float) | (Float, Integer) => Ok(Float),
            (Date, Datetime) | (Datetime, Date) => Ok(Datetime),
            (left, right) => Err((left, right)),
        }
    }
}

fn classify(cell: &CellData) -> Result<CellKind> {
    match cell {
        CellData::Empty => Ok(CellKind::Null),
        CellData::Bool(_) => Ok(CellKind::Boolean),
        CellData::Int(_) => Ok(CellKind::Integer),
        CellData::Float(value)
            if value.is_finite()
                && value.fract() == 0.0
                && *value >= i64::MIN as f64
                && *value <= i64::MAX as f64 =>
        {
            Ok(CellKind::Integer)
        }
        CellData::Float(_) => Ok(CellKind::Float),
        CellData::String(_) => Ok(CellKind::String),
        CellData::DateTime(value) if value.is_duration() => Err(EngineError::Unsupported(
            "Excel duration cells are unsupported".into(),
        )),
        CellData::DateTime(value) => value
            .as_datetime()
            .map(|datetime| {
                if datetime.time() == NaiveTime::MIN {
                    CellKind::Date
                } else {
                    CellKind::Datetime
                }
            })
            .ok_or_else(|| EngineError::Execution("invalid Excel datetime cell".into())),
        CellData::DateTimeIso(value) => {
            if NaiveDate::parse_from_str(value, "%Y-%m-%d").is_ok() {
                Ok(CellKind::Date)
            } else if value.parse::<NaiveDateTime>().is_ok() {
                Ok(CellKind::Datetime)
            } else {
                Err(EngineError::Execution(format!(
                    "invalid ISO 8601 Excel datetime '{value}'"
                )))
            }
        }
        CellData::DurationIso(_) => Err(EngineError::Unsupported(
            "Excel duration cells are unsupported".into(),
        )),
        CellData::Error(error) => Err(EngineError::Execution(format!(
            "Excel cell contains error {error}"
        ))),
    }
}

fn mixed_column(name: &str, left: CellKind, right: CellKind) -> EngineError {
    EngineError::Execution(format!(
        "Excel column '{name}' mixes incompatible {left:?} and {right:?} cells"
    ))
}

fn build_column(
    name: &str,
    column_index: usize,
    rows: &[Vec<CellData>],
    kind: CellKind,
    body_start: usize,
) -> Result<Series> {
    let name_value: PlSmallStr = name.into();
    match kind {
        CellKind::Null => {
            for (row_index, row) in rows.iter().enumerate() {
                let actual = classify(row.get(column_index).unwrap_or(&CellData::Empty))?;
                if actual != CellKind::Null {
                    return Err(outside_inference(name, actual, row_index, body_start));
                }
            }
            Ok(Series::full_null(name_value, rows.len(), &DataType::Null))
        }
        CellKind::Boolean => Ok(Series::new(
            name_value,
            rows.iter()
                .enumerate()
                .map(
                    |(row_index, row)| match row.get(column_index).unwrap_or(&CellData::Empty) {
                        CellData::Empty => Ok(None),
                        CellData::Bool(value) => Ok(Some(*value)),
                        cell => Err(incompatible_value(name, cell, row_index, body_start)),
                    },
                )
                .collect::<Result<Vec<_>>>()?,
        )),
        CellKind::Integer => Ok(Series::new(
            name_value,
            rows.iter()
                .enumerate()
                .map(
                    |(row_index, row)| match row.get(column_index).unwrap_or(&CellData::Empty) {
                        CellData::Empty => Ok(None),
                        CellData::Int(value) => Ok(Some(*value)),
                        CellData::Float(value)
                            if value.is_finite()
                                && value.fract() == 0.0
                                && *value >= i64::MIN as f64
                                && *value <= i64::MAX as f64 =>
                        {
                            Ok(Some(*value as i64))
                        }
                        cell => Err(incompatible_value(name, cell, row_index, body_start)),
                    },
                )
                .collect::<Result<Vec<_>>>()?,
        )),
        CellKind::Float => Ok(Series::new(
            name_value,
            rows.iter()
                .enumerate()
                .map(
                    |(row_index, row)| match row.get(column_index).unwrap_or(&CellData::Empty) {
                        CellData::Empty => Ok(None),
                        CellData::Int(value) => Ok(Some(*value as f64)),
                        CellData::Float(value) => Ok(Some(*value)),
                        cell => Err(incompatible_value(name, cell, row_index, body_start)),
                    },
                )
                .collect::<Result<Vec<_>>>()?,
        )),
        CellKind::String => Ok(Series::new(
            name_value,
            rows.iter()
                .enumerate()
                .map(
                    |(row_index, row)| match row.get(column_index).unwrap_or(&CellData::Empty) {
                        CellData::Empty => Ok(None),
                        CellData::String(value) => Ok(Some(value.clone())),
                        cell => Err(incompatible_value(name, cell, row_index, body_start)),
                    },
                )
                .collect::<Result<Vec<_>>>()?,
        )),
        CellKind::Date => {
            let epoch = unix_epoch_date();
            let values = rows
                .iter()
                .enumerate()
                .map(
                    |(row_index, row)| match row.get(column_index).unwrap_or(&CellData::Empty) {
                        CellData::Empty => Ok(None),
                        cell if classify(cell)? == CellKind::Date => {
                            let date = cell_date(cell)?;
                            let days = date.signed_duration_since(epoch).num_days();
                            i32::try_from(days).map(Some).map_err(|_| {
                                EngineError::Execution(format!(
                                    "Excel date in column '{name}' is outside Polars Date range"
                                ))
                            })
                        }
                        cell => Err(incompatible_value(name, cell, row_index, body_start)),
                    },
                )
                .collect::<Result<Vec<_>>>()?;
            Series::new(name_value, values)
                .cast(&DataType::Date)
                .map_err(Into::into)
        }
        CellKind::Datetime => {
            let values = rows
                .iter()
                .enumerate()
                .map(
                    |(row_index, row)| match row.get(column_index).unwrap_or(&CellData::Empty) {
                        CellData::Empty => Ok(None),
                        cell => match classify(cell)? {
                            CellKind::Date | CellKind::Datetime => {
                                Ok(Some(cell_datetime(cell)?.and_utc().timestamp_millis()))
                            }
                            _ => Err(incompatible_value(name, cell, row_index, body_start)),
                        },
                    },
                )
                .collect::<Result<Vec<_>>>()?;
            Series::new(name_value, values)
                .cast(&DataType::Datetime(TimeUnit::Milliseconds, None))
                .map_err(Into::into)
        }
    }
}

fn outside_inference(name: &str, actual: CellKind, row: usize, body_start: usize) -> EngineError {
    EngineError::Execution(format!(
        "Excel column '{name}' has {actual:?} data at worksheet row {} outside the schema inference boundary",
        row + body_start + 1
    ))
}

fn incompatible_value(name: &str, cell: &CellData, row: usize, body_start: usize) -> EngineError {
    match classify(cell) {
        Ok(actual) => EngineError::Execution(format!(
            "Excel column '{name}' has incompatible {actual:?} data at worksheet row {}",
            row + body_start + 1
        )),
        Err(error) => error,
    }
}

fn cell_date(cell: &CellData) -> Result<NaiveDate> {
    match cell {
        CellData::DateTime(value) => value
            .as_datetime()
            .map(|value| value.date())
            .ok_or_else(|| EngineError::Execution("invalid Excel date cell".into())),
        CellData::DateTimeIso(value) => NaiveDate::parse_from_str(value, "%Y-%m-%d")
            .map_err(|_| EngineError::Execution(format!("invalid Excel date '{value}'"))),
        _ => Err(EngineError::Internal(
            "non-date cell reached Excel date conversion".into(),
        )),
    }
}

fn cell_datetime(cell: &CellData) -> Result<NaiveDateTime> {
    match cell {
        CellData::DateTime(value) => value
            .as_datetime()
            .ok_or_else(|| EngineError::Execution("invalid Excel datetime cell".into())),
        CellData::DateTimeIso(value) => NaiveDate::parse_from_str(value, "%Y-%m-%d")
            .map(|date| date.and_time(NaiveTime::MIN))
            .or_else(|_| value.parse::<NaiveDateTime>())
            .map_err(|_| EngineError::Execution(format!("invalid Excel datetime '{value}'"))),
        _ => Err(EngineError::Internal(
            "non-datetime cell reached Excel datetime conversion".into(),
        )),
    }
}

fn unix_epoch_date() -> NaiveDate {
    NaiveDate::from_ymd_opt(1970, 1, 1).expect("valid Unix epoch")
}

fn write_excel(value: &Value) -> Result<Value> {
    let path = local_path(value)?;
    let frame = registry::frame(b::handle(value, "frame")?)?;
    let worksheet_name = worksheet_name(value, DEFAULT_WORKSHEET)?;
    let include_header = b::optional_bool(value, "includeHeader", true)?;
    let date_format = optional_string(value, "dateFormat")?.unwrap_or("yyyy-mm-dd");
    let datetime_format =
        optional_string(value, "datetimeFormat")?.unwrap_or("yyyy-mm-dd hh:mm:ss.000");
    if date_format.is_empty() || datetime_format.is_empty() {
        return Err(EngineError::Invalid(
            "Excel date formats must not be empty".into(),
        ));
    }
    let header_rows = usize::from(include_header);
    if frame.width() > MAX_EXCEL_COLUMNS {
        return Err(EngineError::Unsupported(format!(
            "DataFrame exceeds Excel's {MAX_EXCEL_COLUMNS} column limit"
        )));
    }
    if frame.height() > MAX_EXCEL_ROWS - header_rows {
        return Err(EngineError::Unsupported(format!(
            "DataFrame exceeds Excel's {MAX_EXCEL_ROWS} row limit"
        )));
    }
    validate_writable_types(&frame)?;

    let mut workbook = Workbook::new();
    let worksheet = workbook
        .add_worksheet()
        .set_name(worksheet_name)
        .map_err(xlsx_write_error)?;
    let date_format = Format::new().set_num_format(date_format);
    let datetime_format = Format::new().set_num_format(datetime_format);
    write_frame(
        worksheet,
        &frame,
        include_header,
        &date_format,
        &datetime_format,
    )?;

    let parent = Path::new(path)
        .parent()
        .filter(|value| !value.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let mut temporary = NamedTempFile::new_in(parent)?;
    workbook
        .save_to_writer(temporary.as_file_mut())
        .map_err(xlsx_write_error)?;
    temporary
        .persist(path)
        .map_err(|error| EngineError::Io(error.error.to_string()))?;
    Ok(json!({"path": path}))
}

fn validate_writable_types(frame: &DataFrame) -> Result<()> {
    for series in frame.materialized_column_iter() {
        match series.dtype() {
            DataType::Null
            | DataType::Boolean
            | DataType::Int8
            | DataType::Int16
            | DataType::Int32
            | DataType::Int64
            | DataType::Int128
            | DataType::UInt8
            | DataType::UInt16
            | DataType::UInt32
            | DataType::UInt64
            | DataType::UInt128
            | DataType::Float32
            | DataType::Float64
            | DataType::String
            | DataType::Date
            | DataType::Datetime(_, None) => {}
            dtype => {
                return Err(EngineError::Unsupported(format!(
                    "Excel writer does not support column '{}' with dtype {dtype}",
                    series.name()
                )))
            }
        }
    }
    Ok(())
}

fn write_frame(
    worksheet: &mut Worksheet,
    frame: &DataFrame,
    include_header: bool,
    date_format: &Format,
    datetime_format: &Format,
) -> Result<()> {
    for (column_index, series) in frame.materialized_column_iter().enumerate() {
        let column = u16::try_from(column_index)
            .map_err(|_| EngineError::Unsupported("too many Excel columns".into()))?;
        if include_header {
            worksheet
                .write_string(0, column, series.name().as_str())
                .map_err(xlsx_write_error)?;
        }
        for row_index in 0..frame.height() {
            let row = u32::try_from(row_index + usize::from(include_header))
                .map_err(|_| EngineError::Unsupported("too many Excel rows".into()))?;
            let cell = series.get(row_index)?;
            write_cell(
                worksheet,
                row,
                column,
                cell,
                series.name().as_str(),
                date_format,
                datetime_format,
            )?;
        }
    }
    Ok(())
}

fn write_cell(
    worksheet: &mut Worksheet,
    row: u32,
    column: u16,
    value: AnyValue<'_>,
    name: &str,
    date_format: &Format,
    datetime_format: &Format,
) -> Result<()> {
    match value {
        AnyValue::Null => {}
        AnyValue::Boolean(value) => {
            worksheet
                .write_boolean(row, column, value)
                .map_err(xlsx_write_error)?;
        }
        AnyValue::Int8(value) => write_integer(worksheet, row, column, value as i128, name)?,
        AnyValue::Int16(value) => write_integer(worksheet, row, column, value as i128, name)?,
        AnyValue::Int32(value) => write_integer(worksheet, row, column, value as i128, name)?,
        AnyValue::Int64(value) => write_integer(worksheet, row, column, value as i128, name)?,
        AnyValue::Int128(value) => write_integer(worksheet, row, column, value, name)?,
        AnyValue::UInt8(value) => write_integer(worksheet, row, column, value as i128, name)?,
        AnyValue::UInt16(value) => write_integer(worksheet, row, column, value as i128, name)?,
        AnyValue::UInt32(value) => write_integer(worksheet, row, column, value as i128, name)?,
        AnyValue::UInt64(value) => write_unsigned(worksheet, row, column, value as u128, name)?,
        AnyValue::UInt128(value) => write_unsigned(worksheet, row, column, value, name)?,
        AnyValue::Float32(value) => write_float(worksheet, row, column, value as f64, name)?,
        AnyValue::Float64(value) => write_float(worksheet, row, column, value, name)?,
        AnyValue::String(value) => {
            worksheet
                .write_string(row, column, value)
                .map_err(xlsx_write_error)?;
        }
        AnyValue::StringOwned(value) => {
            worksheet
                .write_string(row, column, value.as_str())
                .map_err(xlsx_write_error)?;
        }
        AnyValue::Date(value) => {
            let date = unix_epoch_date()
                .checked_add_signed(Duration::days(i64::from(value)))
                .ok_or_else(|| {
                    EngineError::Unsupported(format!(
                        "date in Excel column '{name}' is outside the supported range"
                    ))
                })?;
            worksheet
                .write_datetime_with_format(row, column, date, date_format)
                .map_err(xlsx_write_error)?;
        }
        AnyValue::Datetime(value, unit, None) => {
            write_datetime_cell(worksheet, row, column, value, unit, name, datetime_format)?;
        }
        AnyValue::DatetimeOwned(value, unit, None) => {
            write_datetime_cell(worksheet, row, column, value, unit, name, datetime_format)?;
        }
        other => {
            return Err(EngineError::Unsupported(format!(
                "Excel writer does not support value {other:?} in column '{name}'"
            )))
        }
    }
    Ok(())
}

fn write_integer(
    worksheet: &mut Worksheet,
    row: u32,
    column: u16,
    value: i128,
    name: &str,
) -> Result<()> {
    if !(-MAX_EXACT_EXCEL_INTEGER..=MAX_EXACT_EXCEL_INTEGER).contains(&value) {
        return Err(EngineError::Unsupported(format!(
            "integer {value} in Excel column '{name}' exceeds Excel's exact 53-bit numeric range"
        )));
    }
    worksheet
        .write_number(row, column, value as f64)
        .map_err(xlsx_write_error)?;
    Ok(())
}

fn write_unsigned(
    worksheet: &mut Worksheet,
    row: u32,
    column: u16,
    value: u128,
    name: &str,
) -> Result<()> {
    if value > MAX_EXACT_EXCEL_INTEGER as u128 {
        return Err(EngineError::Unsupported(format!(
            "integer {value} in Excel column '{name}' exceeds Excel's exact 53-bit numeric range"
        )));
    }
    worksheet
        .write_number(row, column, value as f64)
        .map_err(xlsx_write_error)?;
    Ok(())
}

fn write_float(
    worksheet: &mut Worksheet,
    row: u32,
    column: u16,
    value: f64,
    name: &str,
) -> Result<()> {
    if !value.is_finite() {
        return Err(EngineError::Unsupported(format!(
            "non-finite float in Excel column '{name}'"
        )));
    }
    worksheet
        .write_number(row, column, value)
        .map_err(xlsx_write_error)?;
    Ok(())
}

fn write_datetime_cell(
    worksheet: &mut Worksheet,
    row: u32,
    column: u16,
    value: i64,
    unit: TimeUnit,
    name: &str,
    format: &Format,
) -> Result<()> {
    let milliseconds = match unit {
        TimeUnit::Milliseconds => value,
        TimeUnit::Microseconds => value.div_euclid(1_000),
        TimeUnit::Nanoseconds => value.div_euclid(1_000_000),
    };
    let datetime: NaiveDateTime = DateTime::<Utc>::from_timestamp_millis(milliseconds)
        .map(|value| value.naive_utc())
        .ok_or_else(|| {
            EngineError::Unsupported(format!(
                "datetime in Excel column '{name}' is outside the supported range"
            ))
        })?;
    worksheet
        .write_datetime_with_format(row, column, datetime, format)
        .map_err(xlsx_write_error)?;
    Ok(())
}

fn xlsx_write_error(error: rust_xlsxwriter::XlsxError) -> EngineError {
    EngineError::Io(format!("failed to write XLSX workbook: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(command: &str, fields: serde_json::Map<String, Value>) -> Value {
        let mut value = fields;
        value.insert("protocol".into(), json!(2));
        value.insert("command".into(), json!(command));
        Value::Object(value)
    }

    #[test]
    fn xlsx_round_trip_preserves_supported_scalar_columns() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("roundtrip.xlsx");
        let dates = Series::new("date".into(), vec![Some(0i32), Some(1i32)])
            .cast(&DataType::Date)
            .unwrap();
        let datetimes = Series::new("datetime".into(), vec![Some(0i64), Some(1_234i64)])
            .cast(&DataType::Datetime(TimeUnit::Milliseconds, None))
            .unwrap();
        let frame = DataFrame::new(
            2,
            vec![
                Series::new("flag".into(), vec![Some(true), None]).into(),
                Series::new("count".into(), vec![Some(1i64), Some(2i64)]).into(),
                Series::new("ratio".into(), vec![Some(1.5f64), Some(2.5f64)]).into(),
                Series::new("label".into(), vec![Some("a"), Some("b")]).into(),
                dates.into(),
                datetimes.into(),
            ],
        )
        .unwrap();
        let handle = registry::insert(Entry::Frame(frame)).unwrap();
        let write = request(
            "frameWriteExcel",
            serde_json::Map::from_iter([
                ("frame".into(), json!(handle.to_string())),
                ("path".into(), json!(path.to_string_lossy())),
                ("worksheet".into(), json!("Data")),
                ("includeHeader".into(), json!(true)),
            ]),
        );
        dispatch("frameWriteExcel", &write).unwrap().unwrap();

        let read = request(
            "frameReadExcel",
            serde_json::Map::from_iter([
                ("path".into(), json!(path.to_string_lossy())),
                ("worksheet".into(), json!("Data")),
                ("hasHeader".into(), json!(true)),
                ("inferSchemaLength".into(), Value::Null),
            ]),
        );
        let response = dispatch("frameReadExcel", &read).unwrap().unwrap();
        let returned =
            registry::frame(response["handle"].as_str().unwrap().parse().unwrap()).unwrap();
        assert_eq!(returned.shape(), (2, 6));
        assert_eq!(returned["flag"].dtype(), &DataType::Boolean);
        assert_eq!(returned["count"].dtype(), &DataType::Int64);
        assert_eq!(returned["ratio"].dtype(), &DataType::Float64);
        assert_eq!(returned["label"].dtype(), &DataType::String);
        assert_eq!(returned["date"].dtype(), &DataType::Date);
        assert_eq!(
            returned["datetime"].dtype(),
            &DataType::Datetime(TimeUnit::Milliseconds, None)
        );
    }

    #[test]
    fn malformed_workbook_and_mixed_columns_are_rejected() {
        let directory = tempfile::tempdir().unwrap();
        let malformed = directory.path().join("bad.xlsx");
        std::fs::write(&malformed, b"not a workbook").unwrap();
        let request_value = request(
            "frameReadExcel",
            serde_json::Map::from_iter([("path".into(), json!(malformed.to_string_lossy()))]),
        );
        assert!(dispatch("frameReadExcel", &request_value).is_err());

        let mixed = directory.path().join("mixed.xlsx");
        let mut workbook = Workbook::new();
        let worksheet = workbook.add_worksheet();
        worksheet.write_string(0, 0, "value").unwrap();
        worksheet.write_number(1, 0, 1).unwrap();
        worksheet.write_string(2, 0, "two").unwrap();
        workbook.save(&mixed).unwrap();
        let request_value = request(
            "frameReadExcel",
            serde_json::Map::from_iter([
                ("path".into(), json!(mixed.to_string_lossy())),
                ("inferSchemaLength".into(), Value::Null),
            ]),
        );
        let error = dispatch("frameReadExcel", &request_value).unwrap_err();
        assert!(error.to_string().contains("mixes incompatible"));
    }

    #[test]
    fn failed_write_does_not_replace_existing_workbook() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("safe.xlsx");
        std::fs::write(&path, b"original").unwrap();
        let nested = Series::new("items".into(), vec![Series::new("".into(), [1i64, 2i64])]);
        let frame = DataFrame::new(1, vec![nested.into()]).unwrap();
        let handle = registry::insert(Entry::Frame(frame)).unwrap();
        let write = request(
            "frameWriteExcel",
            serde_json::Map::from_iter([
                ("frame".into(), json!(handle.to_string())),
                ("path".into(), json!(path.to_string_lossy())),
            ]),
        );
        assert!(dispatch("frameWriteExcel", &write).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), b"original");
    }
}
