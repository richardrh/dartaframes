use crate::{
    bindings as b,
    error::{EngineError, Result},
    registry::{self, Entry},
};
use base64::Engine as _;
use parking_lot::Mutex;
use polars::prelude::*;
use rusqlite::{
    params_from_iter,
    types::{Value as SqlValue, ValueRef},
    Connection, OpenFlags,
};
use serde_json::{json, Value};
use std::{collections::HashSet, path::Path, sync::Arc};

const MAX_PARAMETERS: usize = 10_000;
const MAX_QUERY_ROWS: usize = 10_000_000;

pub fn invoke(command: &str, request: &Value) -> Result<Value> {
    match command {
        "databaseConnectionOpenSqlite" => {
            fields(request, &["path"])?;
            let path = local_path(request)?;
            let connection = Connection::open_with_flags(
                path,
                OpenFlags::SQLITE_OPEN_READ_WRITE
                    | OpenFlags::SQLITE_OPEN_CREATE
                    | OpenFlags::SQLITE_OPEN_NO_MUTEX,
            )
            .map_err(sql_error)?;
            connection
                .busy_timeout(std::time::Duration::from_secs(5))
                .map_err(sql_error)?;
            let handle =
                registry::insert(Entry::DatabaseConnection(Arc::new(Mutex::new(connection))))?;
            Ok(json!({"handle": handle.to_string(), "kind": "databaseConnection"}))
        }
        "databaseConnectionQuery" => {
            fields(request, &["connection", "sql", "parameters"])?;
            let connection = registry::database_connection(b::handle(request, "connection")?)?;
            let sql = sql_text(request)?;
            let parameters = parameters(request)?;
            let frame = query(&connection.lock(), sql, &parameters)?;
            let handle = registry::insert(Entry::Frame(frame))?;
            Ok(json!({"handle": handle.to_string(), "kind": "frame"}))
        }
        "databaseConnectionExecute" => {
            fields(request, &["connection", "sql", "parameters"])?;
            let connection = registry::database_connection(b::handle(request, "connection")?)?;
            let sql = sql_text(request)?;
            let parameters = parameters(request)?;
            let changed = connection
                .lock()
                .execute(sql, params_from_iter(parameters.iter()))
                .map_err(sql_error)?;
            Ok(json!({"rowsAffected": changed}))
        }
        "databaseConnectionWriteFrame" => {
            fields(request, &["connection", "frame", "table", "ifExists"])?;
            let connection = registry::database_connection(b::handle(request, "connection")?)?;
            let frame = registry::frame(b::handle(request, "frame")?)?;
            let table = b::string(request, "table")?;
            let policy = b::string(request, "ifExists")?;
            let rows = write_frame(&mut connection.lock(), &frame, table, policy)?;
            Ok(json!({"rowsWritten": rows}))
        }
        _ => Err(EngineError::Invalid(format!("unknown command '{command}'"))),
    }
}

fn fields(v: &Value, extra: &[&str]) -> Result<()> {
    let mut allowed = vec!["protocol", "command"];
    allowed.extend(extra);
    b::validate_fields(v, &allowed)
}

fn local_path<'a>(request: &'a Value) -> Result<&'a str> {
    let path = b::string(request, "path")?;
    if path.contains('\0')
        || path == ":memory:"
        || path.starts_with("file:")
        || path.contains("://")
    {
        return Err(EngineError::Invalid(
            "'path' must be a local filesystem path, not a URI or in-memory database".into(),
        ));
    }
    let path_value = Path::new(path);
    if path_value.is_dir() {
        return Err(EngineError::Invalid(
            "'path' must identify a database file".into(),
        ));
    }
    let parent = path_value
        .parent()
        .filter(|value| !value.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    if !parent.is_dir() {
        return Err(EngineError::Io(format!(
            "database parent directory does not exist: {}",
            parent.display()
        )));
    }
    Ok(path)
}

fn sql_text<'a>(request: &'a Value) -> Result<&'a str> {
    let sql = b::string(request, "sql")?;
    if sql.contains('\0') {
        return Err(EngineError::Invalid("'sql' must not contain NUL".into()));
    }
    Ok(sql)
}

fn parameters(request: &Value) -> Result<Vec<SqlValue>> {
    let values = request
        .get("parameters")
        .map(|value| {
            value
                .as_array()
                .ok_or_else(|| EngineError::Invalid("'parameters' must be an array".into()))
        })
        .transpose()?
        .cloned()
        .unwrap_or_default();
    if values.len() > MAX_PARAMETERS {
        return Err(EngineError::Invalid("too many SQL parameters".into()));
    }
    values.iter().map(parameter).collect()
}

fn parameter(value: &Value) -> Result<SqlValue> {
    let object = value
        .as_object()
        .ok_or_else(|| EngineError::Invalid("SQL parameters must be scalar objects".into()))?;
    let allowed = ["dtype", "value", "floatBits", "base64"];
    if object.keys().any(|key| !allowed.contains(&key.as_str())) {
        return Err(EngineError::Invalid(
            "SQL parameter contains an unknown field".into(),
        ));
    }
    let dtype = object
        .get("dtype")
        .and_then(Value::as_object)
        .ok_or_else(|| EngineError::Invalid("SQL parameter dtype must be an object".into()))?;
    let kind = dtype
        .get("kind")
        .and_then(Value::as_str)
        .ok_or_else(|| EngineError::Invalid("SQL parameter dtype.kind must be a string".into()))?;
    let payload_count = ["value", "floatBits", "base64"]
        .iter()
        .filter(|key| object.contains_key(**key))
        .count();
    if payload_count != 1 {
        return Err(EngineError::Invalid(
            "SQL parameter requires exactly one value payload".into(),
        ));
    }
    if object.get("value") == Some(&Value::Null) {
        return Ok(SqlValue::Null);
    }
    match kind {
        "null" => Ok(SqlValue::Null),
        "boolean" => object
            .get("value")
            .and_then(Value::as_bool)
            .map(|v| SqlValue::Integer(i64::from(v)))
            .ok_or_else(|| {
                EngineError::Invalid("boolean SQL parameter must contain a boolean".into())
            }),
        "int8" | "int16" | "int32" | "int64" | "uint8" | "uint16" | "uint32" => {
            let text = object.get("value").and_then(Value::as_str).ok_or_else(|| {
                EngineError::Invalid("integer SQL parameter must contain a decimal string".into())
            })?;
            text.parse::<i64>().map(SqlValue::Integer).map_err(|_| {
                EngineError::Invalid("integer SQL parameter does not fit SQLite int64".into())
            })
        }
        "uint64" => {
            let text = object.get("value").and_then(Value::as_str).ok_or_else(|| {
                EngineError::Invalid("uint64 SQL parameter must contain a decimal string".into())
            })?;
            text.parse::<i64>().map(SqlValue::Integer).map_err(|_| {
                EngineError::Invalid("uint64 SQL parameter does not fit SQLite int64".into())
            })
        }
        "float32" | "float64" => {
            let bits = object
                .get("floatBits")
                .and_then(Value::as_str)
                .ok_or_else(|| {
                    EngineError::Invalid("floating SQL parameter must use floatBits".into())
                })?;
            let raw = u64::from_str_radix(bits, 16)
                .map_err(|_| EngineError::Invalid("invalid floating SQL parameter bits".into()))?;
            let number = if kind == "float32" {
                f32::from_bits(raw as u32) as f64
            } else {
                f64::from_bits(raw)
            };
            if !number.is_finite() {
                return Err(EngineError::Invalid(
                    "SQLite parameters must be finite numbers".into(),
                ));
            }
            Ok(SqlValue::Real(number))
        }
        "string" => object
            .get("value")
            .and_then(Value::as_str)
            .map(|v| SqlValue::Text(v.to_owned()))
            .ok_or_else(|| {
                EngineError::Invalid("string SQL parameter must contain a string".into())
            }),
        "binary" | "binaryOffset" => {
            let encoded = object
                .get("base64")
                .and_then(Value::as_str)
                .ok_or_else(|| {
                    EngineError::Invalid("binary SQL parameter must use base64".into())
                })?;
            base64::engine::general_purpose::STANDARD
                .decode(encoded)
                .map(SqlValue::Blob)
                .map_err(|_| EngineError::Invalid("invalid base64 SQL parameter".into()))
        }
        _ => Err(EngineError::Unsupported(format!(
            "SQLite parameter dtype '{kind}'"
        ))),
    }
}

fn query(connection: &Connection, sql: &str, parameters: &[SqlValue]) -> Result<DataFrame> {
    let mut statement = connection.prepare(sql).map_err(sql_error)?;
    let names = statement
        .column_names()
        .iter()
        .map(|name| (*name).to_owned())
        .collect::<Vec<_>>();
    if names.iter().any(String::is_empty)
        || names.iter().collect::<HashSet<_>>().len() != names.len()
    {
        return Err(EngineError::Execution(
            "SQLite query column names must be non-empty and unique; use AS aliases".into(),
        ));
    }
    let width = names.len();
    let mut columns = vec![Vec::<SqlValue>::new(); width];
    let mut rows = statement
        .query(params_from_iter(parameters.iter()))
        .map_err(sql_error)?;
    while let Some(row) = rows.next().map_err(sql_error)? {
        if columns.first().map_or(0, Vec::len) >= MAX_QUERY_ROWS {
            return Err(EngineError::Execution(
                "SQLite query exceeds the 10000000 row safety limit".into(),
            ));
        }
        for (index, column) in columns.iter_mut().enumerate() {
            column.push(match row.get_ref(index).map_err(sql_error)? {
                ValueRef::Null => SqlValue::Null,
                ValueRef::Integer(v) => SqlValue::Integer(v),
                ValueRef::Real(v) => SqlValue::Real(v),
                ValueRef::Text(v) => {
                    SqlValue::Text(String::from_utf8(v.to_vec()).map_err(|_| {
                        EngineError::Execution("SQLite text result is not valid UTF-8".into())
                    })?)
                }
                ValueRef::Blob(v) => SqlValue::Blob(v.to_vec()),
            });
        }
    }
    let height = columns.first().map_or(0, Vec::len);
    let series = names
        .into_iter()
        .zip(columns)
        .map(|(name, values)| sql_column(&name, values))
        .collect::<Result<Vec<_>>>()?;
    DataFrame::new(height, series.into_iter().map(Into::into).collect()).map_err(Into::into)
}

fn sql_column(name: &str, values: Vec<SqlValue>) -> Result<Series> {
    let has_integer = values.iter().any(|v| matches!(v, SqlValue::Integer(_)));
    let has_real = values.iter().any(|v| matches!(v, SqlValue::Real(_)));
    let has_text = values.iter().any(|v| matches!(v, SqlValue::Text(_)));
    let has_blob = values.iter().any(|v| matches!(v, SqlValue::Blob(_)));
    let kinds =
        usize::from(has_integer || has_real) + usize::from(has_text) + usize::from(has_blob);
    if kinds > 1 {
        return Err(EngineError::Execution(format!(
            "SQLite column '{name}' contains incompatible storage classes"
        )));
    }
    let name: PlSmallStr = name.into();
    if has_real {
        Ok(Series::new(
            name,
            values
                .into_iter()
                .map(|v| match v {
                    SqlValue::Null => None,
                    SqlValue::Integer(x) => Some(x as f64),
                    SqlValue::Real(x) => Some(x),
                    _ => unreachable!(),
                })
                .collect::<Vec<_>>(),
        ))
    } else if has_integer {
        Ok(Series::new(
            name,
            values
                .into_iter()
                .map(|v| match v {
                    SqlValue::Null => None,
                    SqlValue::Integer(x) => Some(x),
                    _ => unreachable!(),
                })
                .collect::<Vec<_>>(),
        ))
    } else if has_text {
        Ok(Series::new(
            name,
            values
                .into_iter()
                .map(|v| match v {
                    SqlValue::Null => None,
                    SqlValue::Text(x) => Some(x),
                    _ => unreachable!(),
                })
                .collect::<Vec<_>>(),
        ))
    } else if has_blob {
        let values = values
            .into_iter()
            .map(|v| match v {
                SqlValue::Null => None,
                SqlValue::Blob(x) => Some(x),
                _ => unreachable!(),
            })
            .collect::<Vec<_>>();
        Ok(
            BinaryChunked::from_iter_options(name, values.iter().map(|v| v.as_deref()))
                .into_series(),
        )
    } else {
        Ok(Series::full_null(name, values.len(), &DataType::Null))
    }
}

fn quote_identifier(value: &str, field: &str) -> Result<String> {
    if value.is_empty() || value.contains('\0') {
        return Err(EngineError::Invalid(format!(
            "'{field}' must be a non-empty SQLite identifier"
        )));
    }
    Ok(format!("\"{}\"", value.replace('"', "\"\"")))
}

fn write_frame(
    connection: &mut Connection,
    frame: &DataFrame,
    table: &str,
    policy: &str,
) -> Result<usize> {
    if frame.width() == 0 {
        return Err(EngineError::Unsupported(
            "writing a zero-column DataFrame to SQLite".into(),
        ));
    }
    if !matches!(policy, "fail" | "replace" | "append") {
        return Err(EngineError::Invalid(
            "'ifExists' must be 'fail', 'replace', or 'append'".into(),
        ));
    }
    let table_name = table;
    let table = quote_identifier(table_name, "table")?;
    let columns = frame.columns();
    let definitions = columns
        .iter()
        .map(|column| {
            Ok(format!(
                "{} {}",
                quote_identifier(column.name(), "column")?,
                sqlite_type(column.dtype())?
            ))
        })
        .collect::<Result<Vec<_>>>()?;
    let names = columns
        .iter()
        .map(|column| quote_identifier(column.name(), "column"))
        .collect::<Result<Vec<_>>>()?;
    let transaction = connection.transaction().map_err(sql_error)?;
    if policy == "replace" {
        transaction
            .execute_batch(&format!("DROP TABLE IF EXISTS {table}"))
            .map_err(sql_error)?;
    }
    if policy != "append" || !table_exists(&transaction, table_name)? {
        let modifier = if policy == "fail" {
            ""
        } else {
            "IF NOT EXISTS "
        };
        transaction
            .execute_batch(&format!(
                "CREATE TABLE {modifier}{table} ({})",
                definitions.join(", ")
            ))
            .map_err(sql_error)?;
    }
    let placeholders = (1..=columns.len())
        .map(|i| format!("?{i}"))
        .collect::<Vec<_>>()
        .join(", ");
    let insert = format!(
        "INSERT INTO {table} ({}) VALUES ({placeholders})",
        names.join(", ")
    );
    let mut statement = transaction.prepare(&insert).map_err(sql_error)?;
    for row in 0..frame.height() {
        let values = columns
            .iter()
            .map(|column| any_value(column.get(row).map_err(EngineError::from)?, column.name()))
            .collect::<Result<Vec<_>>>()?;
        statement
            .execute(params_from_iter(values.iter()))
            .map_err(sql_error)?;
    }
    drop(statement);
    transaction.commit().map_err(sql_error)?;
    Ok(frame.height())
}

fn table_exists(connection: &Connection, table: &str) -> Result<bool> {
    connection
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1)",
            [table],
            |row| row.get(0),
        )
        .map_err(sql_error)
}

fn sqlite_type(dtype: &DataType) -> Result<&'static str> {
    match dtype {
        DataType::Null => Ok("BLOB"),
        DataType::Boolean
        | DataType::Int8
        | DataType::Int16
        | DataType::Int32
        | DataType::Int64
        | DataType::UInt8
        | DataType::UInt16
        | DataType::UInt32 => Ok("INTEGER"),
        DataType::UInt64 => Ok("INTEGER"),
        DataType::Float32 | DataType::Float64 => Ok("REAL"),
        DataType::String => Ok("TEXT"),
        DataType::Binary | DataType::BinaryOffset => Ok("BLOB"),
        other => Err(EngineError::Unsupported(format!(
            "writing Polars dtype '{other}' to SQLite"
        ))),
    }
}

fn any_value(value: AnyValue<'_>, column: &str) -> Result<SqlValue> {
    match value {
        AnyValue::Null => Ok(SqlValue::Null),
        AnyValue::Boolean(v) => Ok(SqlValue::Integer(i64::from(v))),
        AnyValue::Int8(v) => Ok(SqlValue::Integer(v.into())),
        AnyValue::Int16(v) => Ok(SqlValue::Integer(v.into())),
        AnyValue::Int32(v) => Ok(SqlValue::Integer(v.into())),
        AnyValue::Int64(v) => Ok(SqlValue::Integer(v)),
        AnyValue::UInt8(v) => Ok(SqlValue::Integer(v.into())),
        AnyValue::UInt16(v) => Ok(SqlValue::Integer(v.into())),
        AnyValue::UInt32(v) => Ok(SqlValue::Integer(v.into())),
        AnyValue::UInt64(v) => i64::try_from(v).map(SqlValue::Integer).map_err(|_| {
            EngineError::Execution(format!(
                "column '{column}' contains uint64 outside SQLite int64 range"
            ))
        }),
        AnyValue::Float32(v) if v.is_finite() => Ok(SqlValue::Real(v.into())),
        AnyValue::Float64(v) if v.is_finite() => Ok(SqlValue::Real(v)),
        AnyValue::String(v) => Ok(SqlValue::Text(v.to_owned())),
        AnyValue::StringOwned(v) => Ok(SqlValue::Text(v.to_string())),
        AnyValue::Binary(v) => Ok(SqlValue::Blob(v.to_vec())),
        AnyValue::BinaryOwned(v) => Ok(SqlValue::Blob(v)),
        other => Err(EngineError::Unsupported(format!(
            "writing value '{other:?}' in column '{column}' to SQLite"
        ))),
    }
}

fn sql_error(error: rusqlite::Error) -> EngineError {
    EngineError::Execution(format!("SQLite: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn query_parameters_and_frame_write_round_trip() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("test.db");
        let mut connection = Connection::open(path).unwrap();
        connection
            .execute(
                "CREATE TABLE source (id INTEGER, name TEXT, payload BLOB)",
                [],
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO source VALUES (?1, ?2, ?3)",
                (7_i64, "seven", vec![1_u8, 2]),
            )
            .unwrap();
        let frame = query(
            &connection,
            "SELECT id, name, payload FROM source WHERE id = ?1",
            &[SqlValue::Integer(7)],
        )
        .unwrap();
        assert_eq!(frame.shape(), (1, 3));
        assert_eq!(
            write_frame(&mut connection, &frame, "copied", "fail").unwrap(),
            1
        );
        let count: i64 = connection
            .query_row("SELECT count(*) FROM copied", [], |row| row.get(0))
            .unwrap();
        assert_eq!(count, 1);
    }

    #[test]
    fn rejects_mixed_storage_classes_and_non_local_paths() {
        let connection = Connection::open_in_memory().unwrap();
        connection
            .execute_batch("CREATE TABLE t (v); INSERT INTO t VALUES (1), ('one')")
            .unwrap();
        assert!(query(&connection, "SELECT v FROM t", &[]).is_err());
        assert!(local_path(&json!({"path":":memory:"})).is_err());
        assert!(local_path(&json!({"path":"file:test.db"})).is_err());
    }
}
