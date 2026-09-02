use std::{fs::File, num::NonZeroUsize, path::Path, sync::Arc};

use polars::lazy::prelude::{FileWriteFormat, SinkDestination, SinkTarget, UnifiedSinkArgs};
use polars::prelude::*;
use polars_utils::{pl_path::PlRefPath, slice_enum::Slice};
use serde_json::{json, Value};
use tempfile::NamedTempFile;

use crate::{
    bindings as b,
    error::{EngineError, Result},
    registry::{self, Entry},
};

fn fields(v: &Value, extra: &[&str]) -> Result<()> {
    let mut allowed = vec!["protocol", "command"];
    allowed.extend(extra);
    b::validate_fields(v, &allowed)
}

fn path(v: &Value) -> Result<&str> {
    let path = b::string(v, "path")?;
    if path.len() > 1_048_576 {
        return Err(EngineError::Invalid("invalid path length".into()));
    }
    if path.contains("://") {
        return Err(EngineError::Unsupported(
            "only local filesystem paths are supported".into(),
        ));
    }
    Ok(path)
}

fn usize_opt(v: &Value, key: &str) -> Result<Option<usize>> {
    v.get(key)
        .map(|x| {
            x.as_u64()
                .ok_or_else(|| EngineError::Invalid(format!("'{key}' must be unsigned")))
                .and_then(|x| {
                    usize::try_from(x)
                        .map_err(|_| EngineError::Invalid(format!("'{key}' is too large")))
                })
        })
        .transpose()
}

fn nonzero_opt(v: &Value, key: &str) -> Result<Option<NonZeroUsize>> {
    if v.get(key).is_some_and(Value::is_null) {
        return Ok(None);
    }
    usize_opt(v, key)?
        .map(|x| {
            NonZeroUsize::new(x)
                .ok_or_else(|| EngineError::Invalid(format!("'{key}' must be positive")))
        })
        .transpose()
}

fn names_opt(v: &Value, key: &str) -> Result<Option<Vec<String>>> {
    v.get(key)
        .map(|_| b::names(v, key).map(|names| names.into_iter().map(|x| x.to_string()).collect()))
        .transpose()
}

fn temporary(path: &str) -> Result<NamedTempFile> {
    let parent = Path::new(path)
        .parent()
        .filter(|x| !x.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let file = NamedTempFile::new_in(parent)?;
    if let Ok(metadata) = std::fs::metadata(path) {
        file.as_file().set_permissions(metadata.permissions())?;
    }
    Ok(file)
}

fn persist(file: NamedTempFile, path: &str) -> Result<()> {
    file.persist(path)
        .map(|_| ())
        .map_err(|e| EngineError::Io(e.error.to_string()))
}

fn ipc_compression(v: &Value) -> Result<Option<IpcCompression>> {
    let value = v
        .get("compression")
        .map(|x| {
            x.as_str()
                .ok_or_else(|| EngineError::Invalid("'compression' must be a string".into()))
        })
        .transpose()?
        .unwrap_or("none");
    match value {
        "none" | "uncompressed" => Ok(None),
        "lz4" => Ok(Some(IpcCompression::LZ4)),
        "zstd" => Ok(Some(IpcCompression::ZSTD(Default::default()))),
        _ => Err(EngineError::Unsupported(format!(
            "IPC compression '{value}'"
        ))),
    }
}

fn parquet_compression(v: &Value) -> Result<ParquetCompression> {
    let compression = v
        .get("compression")
        .map(|x| {
            x.as_str()
                .ok_or_else(|| EngineError::Invalid("'compression' must be a string".into()))
        })
        .transpose()?
        .unwrap_or("zstd");
    Ok(match compression {
        "none" | "uncompressed" => ParquetCompression::Uncompressed,
        "snappy" => ParquetCompression::Snappy,
        "gzip" => ParquetCompression::Gzip(None),
        "brotli" => ParquetCompression::Brotli(None),
        "zstd" => ParquetCompression::Zstd(None),
        "lz4" | "lz4raw" => ParquetCompression::Lz4Raw,
        value => {
            return Err(EngineError::Unsupported(format!(
                "Parquet compression '{value}'"
            )))
        }
    })
}

fn string_opt<'a>(v: &'a Value, key: &str) -> Result<Option<&'a str>> {
    v.get(key)
        .map(|x| {
            x.as_str()
                .ok_or_else(|| EngineError::Invalid(format!("'{key}' must be a string")))
        })
        .transpose()
}

fn byte(v: &Value, key: &str, default: u8) -> Result<u8> {
    match string_opt(v, key)? {
        None => Ok(default),
        Some(value) if value.as_bytes().len() == 1 => Ok(value.as_bytes()[0]),
        Some(_) => Err(EngineError::Invalid(format!("'{key}' must be one byte"))),
    }
}

fn parquet_statistics(v: &Value) -> Result<StatisticsOptions> {
    Ok(StatisticsOptions {
        min_value: b::optional_bool(v, "statisticsMin", true)?,
        max_value: b::optional_bool(v, "statisticsMax", true)?,
        distinct_count: b::optional_bool(v, "statisticsDistinctCount", false)?,
        null_count: b::optional_bool(v, "statisticsNullCount", true)?,
        binary_statistics_truncate_length: v
            .get("statisticsBinaryTruncateLength")
            .map(|x| {
                x.as_u64().ok_or_else(|| {
                    EngineError::Invalid("'statisticsBinaryTruncateLength' must be unsigned".into())
                })
            })
            .transpose()?,
    })
}

fn frame_response(frame: DataFrame) -> Result<Value> {
    let handle = registry::insert(Entry::Frame(frame))?;
    Ok(json!({"handle":handle.to_string(),"kind":"frame"}))
}

fn scan_ipc(v: &Value) -> Result<Value> {
    let mut args = UnifiedScanArgs {
        cache: b::optional_bool(v, "cache", false)?,
        rechunk: b::optional_bool(v, "rechunk", false)?,
        ..Default::default()
    };
    args.pre_slice = usize_opt(v, "nRows")?.map(|len| Slice::Positive { offset: 0, len });
    let options = IpcScanOptions {
        record_batch_statistics: b::optional_bool(v, "recordBatchStatistics", false)?,
        ..Default::default()
    };
    let frame = LazyFrame::scan_ipc(path(v)?.into(), options, args)?;
    let handle = registry::insert(Entry::LazyFrame(Box::new(frame)))?;
    Ok(json!({"handle":handle.to_string(),"kind":"lazyFrame"}))
}

fn scan_ndjson(v: &Value) -> Result<Value> {
    let mut reader = LazyJsonLineReader::new(path(v)?.into())
        .with_n_rows(usize_opt(v, "nRows")?)
        .with_infer_schema_length(nonzero_opt(v, "inferSchemaLength")?)
        .with_ignore_errors(b::optional_bool(v, "ignoreErrors", false)?)
        .low_memory(b::optional_bool(v, "lowMemory", false)?)
        .with_rechunk(b::optional_bool(v, "rechunk", false)?);
    // Keep Polars' default (100) when the option was omitted.
    if v.get("inferSchemaLength").is_none() {
        reader = reader.with_infer_schema_length(NonZeroUsize::new(100));
    }
    let handle = registry::insert(Entry::LazyFrame(Box::new(reader.finish()?)))?;
    Ok(json!({"handle":handle.to_string(),"kind":"lazyFrame"}))
}

fn read_json(v: &Value) -> Result<Value> {
    let mut reader = JsonReader::new(File::open(path(v)?)?)
        .set_rechunk(b::optional_bool(v, "rechunk", true)?)
        .with_json_format(JsonFormat::Json);
    if v.get("inferSchemaLength").is_some() {
        reader = reader.infer_schema_len(nonzero_opt(v, "inferSchemaLength")?);
    }
    if let Some(size) = nonzero_opt(v, "batchSize")? {
        reader = reader.with_batch_size(size);
    }
    frame_response(reader.finish()?)
}

fn read_ipc_stream(v: &Value) -> Result<Value> {
    frame_response(
        IpcStreamReader::new(File::open(path(v)?)?)
            .set_rechunk(b::optional_bool(v, "rechunk", true)?)
            .with_n_rows(usize_opt(v, "nRows")?)
            .with_columns(names_opt(v, "columns")?)
            .finish()?,
    )
}

fn write_frame(v: &Value, format: &str) -> Result<Value> {
    let mut frame = registry::frame(b::handle(v, "frame")?)?;
    let output = path(v)?;
    let mut file = temporary(output)?;
    match format {
        "ipc" => {
            IpcWriter::new(file.as_file_mut())
                .with_compression(ipc_compression(v)?)
                .with_record_batch_size(usize_opt(v, "recordBatchSize")?)
                .with_parallel(b::optional_bool(v, "parallel", true)?)
                .with_record_batch_statistics(b::optional_bool(v, "recordBatchStatistics", false)?)
                .finish(&mut frame)?;
        }
        "ipcStream" => {
            IpcStreamWriter::new(file.as_file_mut())
                .with_compression(ipc_compression(v)?)
                .finish(&mut frame)?;
        }
        "json" => {
            JsonWriter::new(file.as_file_mut())
                .with_json_format(JsonFormat::Json)
                .finish(&mut frame)?;
        }
        "ndjson" => {
            JsonWriter::new(file.as_file_mut())
                .with_json_format(JsonFormat::JsonLines)
                .finish(&mut frame)?;
        }
        _ => unreachable!(),
    }
    persist(file, output)?;
    Ok(json!({"path":output}))
}

fn sink(v: &Value, format: &str) -> Result<Value> {
    let output = path(v)?;
    let file = temporary(output)?;
    let temp_path = PlRefPath::try_from_path(file.path())?;
    let file_format = match format {
        "csv" => {
            let separator = v
                .get("separator")
                .map(|x| {
                    x.as_str()
                        .ok_or_else(|| EngineError::Invalid("'separator' must be a string".into()))
                })
                .transpose()?
                .unwrap_or(",");
            if separator.as_bytes().len() != 1 {
                return Err(EngineError::Invalid("separator must be one byte".into()));
            }
            let mut options = CsvWriterOptions {
                include_bom: b::optional_bool(v, "includeBom", false)?,
                include_header: b::optional_bool(v, "includeHeader", true)?,
                batch_size: nonzero_opt(v, "batchSize")?
                    .unwrap_or(NonZeroUsize::new(1024).unwrap()),
                ..Default::default()
            };
            let serialize = Arc::make_mut(&mut options.serialize_options);
            serialize.separator = separator.as_bytes()[0];
            serialize.date_format = string_opt(v, "dateFormat")?.map(Into::into);
            serialize.time_format = string_opt(v, "timeFormat")?.map(Into::into);
            serialize.datetime_format = string_opt(v, "datetimeFormat")?.map(Into::into);
            serialize.float_scientific = v
                .get("floatScientific")
                .map(|x| {
                    x.as_bool().ok_or_else(|| {
                        EngineError::Invalid("'floatScientific' must be a boolean".into())
                    })
                })
                .transpose()?;
            serialize.float_precision = usize_opt(v, "floatPrecision")?;
            serialize.decimal_comma = b::optional_bool(v, "decimalComma", false)?;
            serialize.quote_char = byte(v, "quoteChar", b'"')?;
            serialize.null = string_opt(v, "nullValue")?.unwrap_or("").into();
            serialize.line_terminator = string_opt(v, "lineTerminator")?.unwrap_or("\n").into();
            serialize.quote_style = match string_opt(v, "quoteStyle")?.unwrap_or("necessary") {
                "necessary" => QuoteStyle::Necessary,
                "always" => QuoteStyle::Always,
                "nonNumeric" => QuoteStyle::NonNumeric,
                "never" => QuoteStyle::Never,
                x => {
                    return Err(EngineError::Invalid(format!(
                        "invalid CSV quote style '{x}'"
                    )))
                }
            };
            FileWriteFormat::Csv(options)
        }
        "parquet" => {
            let options = ParquetWriteOptions {
                compression: parquet_compression(v)?,
                statistics: parquet_statistics(v)?,
                row_group_size: nonzero_opt(v, "rowGroupSize")?.map(|x| x.get()),
                data_page_size: nonzero_opt(v, "dataPageSize")?.map(|x| x.get()),
                ..Default::default()
            };
            FileWriteFormat::Parquet(Arc::new(options))
        }
        "ipc" => FileWriteFormat::Ipc(IpcWriterOptions {
            compression: ipc_compression(v)?,
            record_batch_size: usize_opt(v, "recordBatchSize")?,
            record_batch_statistics: b::optional_bool(v, "recordBatchStatistics", false)?,
            ..Default::default()
        }),
        "ndjson" => FileWriteFormat::NDJson(NDJsonWriterOptions::default()),
        _ => unreachable!(),
    };
    registry::lazy_frame(b::handle(v, "input")?)?
        .sink(
            SinkDestination::File {
                target: SinkTarget::Path(temp_path),
            },
            file_format,
            UnifiedSinkArgs {
                maintain_order: b::optional_bool(v, "maintainOrder", true)?,
                ..Default::default()
            },
        )?
        .collect()?;
    persist(file, output)?;
    Ok(json!({"path":output,"execution":"nativeLazySink"}))
}

pub fn dispatch(command: &str, v: &Value) -> Result<Option<Value>> {
    let output = match command {
        "lazyScanIpc" => {
            fields(
                v,
                &["path", "nRows", "cache", "rechunk", "recordBatchStatistics"],
            )?;
            scan_ipc(v)?
        }
        "lazyScanNdjson" => {
            fields(
                v,
                &[
                    "path",
                    "nRows",
                    "inferSchemaLength",
                    "ignoreErrors",
                    "lowMemory",
                    "rechunk",
                ],
            )?;
            scan_ndjson(v)?
        }
        "frameReadJson" => {
            fields(v, &["path", "inferSchemaLength", "batchSize", "rechunk"])?;
            read_json(v)?
        }
        "frameReadIpcStream" => {
            fields(v, &["path", "nRows", "columns", "rechunk"])?;
            read_ipc_stream(v)?
        }
        "frameWriteIpc" => {
            fields(
                v,
                &[
                    "frame",
                    "path",
                    "compression",
                    "recordBatchSize",
                    "parallel",
                    "recordBatchStatistics",
                ],
            )?;
            write_frame(v, "ipc")?
        }
        "frameWriteIpcStream" => {
            fields(v, &["frame", "path", "compression"])?;
            write_frame(v, "ipcStream")?
        }
        "frameWriteJson" => {
            fields(v, &["frame", "path"])?;
            write_frame(v, "json")?
        }
        "frameWriteNdjson" => {
            fields(v, &["frame", "path"])?;
            write_frame(v, "ndjson")?
        }
        "lazySinkCsv" => {
            fields(
                v,
                &[
                    "input",
                    "path",
                    "includeHeader",
                    "separator",
                    "maintainOrder",
                    "includeBom",
                    "batchSize",
                    "dateFormat",
                    "timeFormat",
                    "datetimeFormat",
                    "floatScientific",
                    "floatPrecision",
                    "decimalComma",
                    "quoteChar",
                    "nullValue",
                    "lineTerminator",
                    "quoteStyle",
                ],
            )?;
            sink(v, "csv")?
        }
        "lazySinkParquet" => {
            fields(
                v,
                &[
                    "input",
                    "path",
                    "compression",
                    "maintainOrder",
                    "rowGroupSize",
                    "dataPageSize",
                    "statisticsMin",
                    "statisticsMax",
                    "statisticsDistinctCount",
                    "statisticsNullCount",
                    "statisticsBinaryTruncateLength",
                ],
            )?;
            sink(v, "parquet")?
        }
        "lazySinkIpc" => {
            fields(
                v,
                &[
                    "input",
                    "path",
                    "compression",
                    "recordBatchSize",
                    "recordBatchStatistics",
                    "maintainOrder",
                ],
            )?;
            sink(v, "ipc")?
        }
        "lazySinkNdjson" => {
            fields(v, &["input", "path", "maintainOrder"])?;
            sink(v, "ndjson")?
        }
        _ => return Ok(None),
    };
    Ok(Some(output))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ipc_options_are_closed_and_exact() {
        assert!(ipc_compression(&json!({"compression":"lz4"}))
            .unwrap()
            .is_some());
        assert!(ipc_compression(&json!({"compression":"snappy"})).is_err());
        assert!(nonzero_opt(&json!({"n":0}), "n").is_err());
        assert!(dispatch(
            "lazyScanIpc",
            &json!({"protocol":2,"command":"lazyScanIpc","path":"x.ipc","cloud":true})
        )
        .is_err());
    }

    #[test]
    fn parquet_statistics_and_csv_bytes_are_validated() {
        let statistics = parquet_statistics(&json!({
            "statisticsMin": false,
            "statisticsDistinctCount": true,
            "statisticsBinaryTruncateLength": 16
        }))
        .unwrap();
        assert!(!statistics.min_value);
        assert!(statistics.distinct_count);
        assert_eq!(statistics.binary_statistics_truncate_length, Some(16));
        assert_eq!(byte(&json!({"quoteChar":"'"}), "quoteChar", b'"').unwrap(), b'\'');
        assert!(byte(&json!({"quoteChar":"é"}), "quoteChar", b'"').is_err());
        assert!(nonzero_opt(&json!({"rowGroupSize":0}), "rowGroupSize").is_err());
    }
}
