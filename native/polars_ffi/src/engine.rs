use crate::{
    batch, batch_stream, bindings as b, dtype, eager,
    error::{EngineError, Result},
    io_extended,
    jobs::Job,
    namespace_expr,
    registry::{self, Entry},
    selectors, sql, sqlite, temporal_relational,
};
use polars::prelude::*;
use serde_json::{json, Value};
use std::{num::NonZeroUsize, path::Path};
use tempfile::NamedTempFile;

fn response(handle: u64, kind: &str) -> Value {
    json!({"handle":handle.to_string(),"kind":kind})
}
fn fields(v: &Value, extra: &[&str]) -> Result<()> {
    let mut allowed = vec!["protocol", "command"];
    allowed.extend(extra);
    b::validate_fields(v, &allowed)
}
fn insert(entry: Entry, kind: &str) -> Result<Value> {
    Ok(response(registry::insert(entry)?, kind))
}

pub fn invoke(bytes: &[u8]) -> Result<Value> {
    if bytes.len() > 64 * 1024 * 1024 {
        return Err(EngineError::Invalid("request exceeds 64 MiB".into()));
    }
    let r: Value = serde_json::from_slice(bytes)
        .map_err(|e| EngineError::Invalid(format!("invalid JSON: {e}")))?;
    let version = r
        .get("protocol")
        .and_then(Value::as_u64)
        .ok_or_else(|| EngineError::Protocol("protocol is required".into()))?;
    if version != 2 {
        return Err(EngineError::Protocol(format!(
            "unsupported protocol version {version}"
        )));
    }
    let command = r
        .get("command")
        .and_then(Value::as_str)
        .ok_or_else(|| EngineError::Invalid("command must be a string".into()))?;
    if let Some(payload) = eager::dispatch(command, &r)? {
        let mut out = json!({"ok":true});
        if let (Some(dst), Some(src)) = (out.as_object_mut(), payload.as_object()) {
            dst.extend(src.clone())
        } else {
            out["result"] = payload
        }
        return Ok(out);
    }
    if let Some(payload) = io_extended::dispatch(command, &r)? {
        return envelope(payload);
    }
    if command.starts_with("selector") || command.starts_with("dtypeSelector") {
        return envelope(selectors::invoke(command, &r)?);
    }
    if command.starts_with("sqlContext") {
        return envelope(sql::invoke(command, &r)?);
    }
    if command.starts_with("databaseConnection") {
        return envelope(sqlite::invoke(command, &r)?);
    }
    let payload = match command {
        "hello" => {
            fields(&r, &[])?;
            hello()
        }
        "runtimeDiagnostics" => {
            fields(&r, &[])?;
            registry::diagnostics()
        }
        "frameImport" => {
            fields(&r, &["batch"])?;
            insert(Entry::Frame(batch::import(b::req(&r, "batch")?)?), "frame")?
        }
        "frameInfo" => {
            fields(&r, &["frame"])?;
            batch::info(&registry::frame(b::handle(&r, "frame")?)?)
        }
        "frameExport" => {
            fields(&r, &["frame"])?;
            json!({"batch":batch::export(&registry::frame(b::handle(&r,"frame")?)?)?})
        }
        "frameLazy" => {
            fields(&r, &["frame"])?;
            insert(
                Entry::LazyFrame(Box::new(registry::frame(b::handle(&r, "frame")?)?.lazy())),
                "lazyFrame",
            )?
        }
        "frameWriteCsv" => {
            fields(
                &r,
                &[
                    "frame",
                    "path",
                    "includeHeader",
                    "separator",
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
                    "nThreads",
                ],
            )?;
            write_csv(&r)?
        }
        "frameWriteParquet" => {
            fields(
                &r,
                &[
                    "frame",
                    "path",
                    "compression",
                    "rowGroupSize",
                    "dataPageSize",
                    "statisticsMin",
                    "statisticsMax",
                    "statisticsDistinctCount",
                    "statisticsNullCount",
                    "statisticsBinaryTruncateLength",
                    "parallel",
                ],
            )?;
            write_parquet(&r)?
        }
        "lazyCollect" => {
            fields(&r, execution_fields())?;
            let lazy = execution_lazy(&r)?;
            insert(
                Entry::Frame(
                    lazy.collect_with_engine(execution_engine(&r)?)?
                        .unwrap_single(),
                ),
                "frame",
            )?
        }
        "lazySubmit" => {
            fields(&r, execution_fields())?;
            insert(
                Entry::Job(Job::submit(execution_lazy(&r)?, execution_engine(&r)?)?),
                "job",
            )?
        }
        "lazyProfile" => {
            fields(&r, optimizer_fields())?;
            let (result, timings) = execution_lazy(&r)?.profile()?;
            let handles = registry::insert_many(vec![Entry::Frame(result), Entry::Frame(timings)])?;
            json!({
                "resultHandle": handles[0].to_string(),
                "timingsHandle": handles[1].to_string(),
                "kind": "profile",
            })
        }
        "jobPoll" => {
            fields(&r, &["job"])?;
            registry::job(b::handle(&r, "job")?)?.poll()
        }
        "jobCancel" => {
            fields(&r, &["job"])?;
            registry::job(b::handle(&r, "job")?)?.cancel()
        }
        "jobTake" => {
            fields(&r, &["job"])?;
            match registry::job(b::handle(&r, "job")?)?.take()? {
                Some(df) => {
                    let mut x = insert(Entry::Frame(df), "frame")?;
                    x["ready"] = json!(true);
                    x
                }
                None => json!({"ready":false}),
            }
        }
        "lazyBatchStream" => {
            fields(&r, &["input", "batchRows", "capacity", "engine"])?;
            let rows = bounded_usize(&r, "batchRows", 1, 10_000_000)?;
            let capacity = bounded_usize(&r, "capacity", 1, 64)?;
            insert(
                Entry::BatchStream(batch_stream::BatchStream::submit(
                    registry::lazy_frame(b::handle(&r, "input")?)?,
                    rows,
                    capacity,
                    execution_engine(&r)?,
                )),
                "batchStream",
            )?
        }
        "batchStreamPoll" => {
            fields(&r, &["stream"])?;
            let (mut state, frame) = registry::batch_stream(b::handle(&r, "stream")?)?.poll()?;
            if let Some(frame) = frame {
                let handle = registry::insert(Entry::Frame(frame))?;
                state["handle"] = json!(handle.to_string());
                state["kind"] = json!("frame");
            }
            state
        }
        "batchStreamCancel" => {
            fields(&r, &["stream"])?;
            registry::batch_stream(b::handle(&r, "stream")?)?.cancel()
        }
        "exprColumn" => {
            fields(&r, &["name"])?;
            insert(Entry::Expr(col(b::string(&r, "name")?)), "expr")?
        }
        "exprLiteral" => {
            fields(&r, &["scalar"])?;
            insert(Entry::Expr(b::literal(b::req(&r, "scalar")?)?), "expr")?
        }
        "exprLen" => {
            fields(&r, &[])?;
            insert(Entry::Expr(len()), "expr")?
        }
        "exprAlias" => {
            fields(&r, &["input", "name"])?;
            insert(
                Entry::Expr(registry::expr(b::handle(&r, "input")?)?.alias(b::string(&r, "name")?)),
                "expr",
            )?
        }
        "exprCast" => {
            fields(&r, &["input", "dtype", "strict"])?;
            let x = registry::expr(b::handle(&r, "input")?)?;
            let dt = dtype::parse(b::req(&r, "dtype")?)?;
            insert(
                Entry::Expr(if b::optional_bool(&r, "strict", true)? {
                    x.strict_cast(dt)
                } else {
                    x.cast(dt)
                }),
                "expr",
            )?
        }
        "exprUnary" => {
            fields(&r, &["input", "op"])?;
            insert(Entry::Expr(b::unary(&r)?), "expr")?
        }
        "exprBinary" => {
            fields(&r, &["left", "right", "op"])?;
            insert(Entry::Expr(b::binary(&r)?), "expr")?
        }
        "exprTernary" => {
            fields(&r, &["predicate", "truthy", "falsy"])?;
            let e = when(registry::expr(b::handle(&r, "predicate")?)?)
                .then(registry::expr(b::handle(&r, "truthy")?)?)
                .otherwise(registry::expr(b::handle(&r, "falsy")?)?);
            insert(Entry::Expr(e), "expr")?
        }
        "exprAggregate" => {
            fields(
                &r,
                &[
                    "input",
                    "op",
                    "ddof",
                    "quantile",
                    "interpolation",
                    "maintainOrder",
                    "bias",
                    "fisher",
                    "ignoreNulls",
                ],
            )?;
            validate_aggregate_fields(&r)?;
            insert(Entry::Expr(b::aggregate(&r)?), "expr")?
        }
        "exprFunction" => insert(Entry::Expr(b::function(&r)?), "expr")?,
        "exprMeta" => namespace_expr::metadata(&r)?,
        "exprOver" => {
            fields(
                &r,
                &[
                    "input",
                    "partitionBy",
                    "orderBy",
                    "mapping",
                    "orderDescending",
                    "orderNullsLast",
                    "orderMaintainOrder",
                    "orderMultithreaded",
                ],
            )?;
            insert(Entry::Expr(temporal_relational::over(&r)?), "expr")?
        }
        "lazyScanCsv" => {
            fields(
                &r,
                &[
                    "path",
                    "hasHeader",
                    "separator",
                    "skipRows",
                    "nRows",
                    "tryParseDates",
                ],
            )?;
            insert(Entry::LazyFrame(Box::new(b::scan_csv(&r)?)), "lazyFrame")?
        }
        "lazyScanParquet" => {
            fields(&r, &["path", "nRows", "parallel"])?;
            insert(
                Entry::LazyFrame(Box::new(b::scan_parquet(&r)?)),
                "lazyFrame",
            )?
        }
        "lazySchema" => {
            fields(&r, &["input"])?;
            json!({"schema":b::schema(&registry::lazy_frame(b::handle(&r,"input")?)?)?})
        }
        "lazyExplain" => {
            fields(&r, &["input", "optimized", "format"])?;
            let lazy = registry::lazy_frame(b::handle(&r, "input")?)?;
            let optimized = b::boolean(&r, "optimized")?;
            let format = r
                .get("format")
                .map(|value| {
                    value
                        .as_str()
                        .ok_or_else(|| EngineError::Invalid("'format' must be a string".into()))
                })
                .transpose()?
                .unwrap_or("plain");
            let explanation = match format {
                "plain" => lazy.explain(optimized)?,
                "tree" if optimized => lazy.describe_optimized_plan_tree()?,
                "tree" => lazy.describe_plan_tree()?,
                "dot" => lazy.to_dot(optimized)?,
                format => {
                    return Err(EngineError::Invalid(format!(
                        "unknown explain format '{format}'"
                    )))
                }
            };
            json!({"explanation": explanation})
        }
        "lazySelectInputs" => {
            fields(&r, &["input", "expressions"])?;
            insert(
                Entry::LazyFrame(Box::new(
                    registry::lazy_frame(b::handle(&r, "input")?)?
                        .select(b::expr_inputs(&r, "expressions")?),
                )),
                "lazyFrame",
            )?
        }
        "lazyWithColumnsInputs" => {
            fields(&r, &["input", "expressions"])?;
            insert(
                Entry::LazyFrame(Box::new(
                    registry::lazy_frame(b::handle(&r, "input")?)?
                        .with_columns(b::expr_inputs(&r, "expressions")?),
                )),
                "lazyFrame",
            )?
        }
        c @ ("lazyJoinAsOf" | "lazyJoinWhere" | "lazyGroupByDynamic" | "lazyGroupByRolling") => {
            validate_lazy_fields(&r, c)?;
            insert(
                Entry::LazyFrame(Box::new(temporal_relational::lazy(&r, c)?)),
                "lazyFrame",
            )?
        }
        c if c.starts_with("lazy") => {
            validate_lazy_fields(&r, c)?;
            insert(Entry::LazyFrame(Box::new(b::lazy(&r, c)?)), "lazyFrame")?
        }
        x => return Err(EngineError::Invalid(format!("unknown command '{x}'"))),
    };
    let mut out = json!({"ok":true});
    if let (Some(dst), Some(src)) = (out.as_object_mut(), payload.as_object()) {
        dst.extend(src.clone())
    } else {
        out["result"] = payload
    }
    Ok(out)
}

fn envelope(payload: Value) -> Result<Value> {
    let mut out = json!({"ok":true});
    if let (Some(dst), Some(src)) = (out.as_object_mut(), payload.as_object()) {
        dst.extend(src.clone())
    } else {
        out["result"] = payload
    }
    Ok(out)
}

const OPTIMIZER_FIELDS: [&str; 15] = [
    "input",
    "projectionPushdown",
    "predicatePushdown",
    "clusterWithColumns",
    "typeCoercion",
    "simplifyExpression",
    "typeCheck",
    "slicePushdown",
    "commonSubplanElimination",
    "commonSubexpressionElimination",
    "rowEstimate",
    "fastProjection",
    "checkOrderObserve",
    "sortCollapse",
    "partitionHive",
];

fn optimizer_fields() -> &'static [&'static str] {
    &OPTIMIZER_FIELDS
}

fn execution_fields() -> &'static [&'static str] {
    const FIELDS: [&str; 16] = [
        "input",
        "engine",
        "projectionPushdown",
        "predicatePushdown",
        "clusterWithColumns",
        "typeCoercion",
        "simplifyExpression",
        "typeCheck",
        "slicePushdown",
        "commonSubplanElimination",
        "commonSubexpressionElimination",
        "rowEstimate",
        "fastProjection",
        "checkOrderObserve",
        "sortCollapse",
        "partitionHive",
    ];
    &FIELDS
}

fn execution_engine(v: &Value) -> Result<Engine> {
    let engine = v
        .get("engine")
        .map(|value| {
            value
                .as_str()
                .ok_or_else(|| EngineError::Invalid("'engine' must be a string".into()))
        })
        .transpose()?
        .unwrap_or("auto");
    Ok(match engine {
        "auto" => Engine::Auto,
        "in-memory" => Engine::InMemory,
        "streaming" => Engine::Streaming,
        engine => {
            return Err(EngineError::Invalid(format!(
                "unknown execution engine '{engine}'"
            )))
        }
    })
}

fn bounded_usize(v: &Value, key: &str, minimum: usize, maximum: usize) -> Result<usize> {
    let raw = b::req(v, key)?
        .as_u64()
        .ok_or_else(|| EngineError::Invalid(format!("'{key}' must be unsigned")))?;
    let value =
        usize::try_from(raw).map_err(|_| EngineError::Invalid(format!("'{key}' is too large")))?;
    if !(minimum..=maximum).contains(&value) {
        return Err(EngineError::Invalid(format!(
            "'{key}' must be in {minimum}..={maximum}"
        )));
    }
    Ok(value)
}

fn execution_lazy(v: &Value) -> Result<LazyFrame> {
    let lazy = registry::lazy_frame(b::handle(v, "input")?)?;
    let mut flags = lazy.get_current_optimizations();
    for (field, flag) in [
        ("projectionPushdown", OptFlags::PROJECTION_PUSHDOWN),
        ("predicatePushdown", OptFlags::PREDICATE_PUSHDOWN),
        ("clusterWithColumns", OptFlags::CLUSTER_WITH_COLUMNS),
        ("typeCoercion", OptFlags::TYPE_COERCION),
        ("simplifyExpression", OptFlags::SIMPLIFY_EXPR),
        ("typeCheck", OptFlags::TYPE_CHECK),
        ("slicePushdown", OptFlags::SLICE_PUSHDOWN),
        ("commonSubplanElimination", OptFlags::COMM_SUBPLAN_ELIM),
        (
            "commonSubexpressionElimination",
            OptFlags::COMM_SUBEXPR_ELIM,
        ),
        ("rowEstimate", OptFlags::ROW_ESTIMATE),
        ("fastProjection", OptFlags::FAST_PROJECTION),
        ("checkOrderObserve", OptFlags::CHECK_ORDER_OBSERVE),
        ("sortCollapse", OptFlags::SORT_COLLAPSE),
        ("partitionHive", OptFlags::PARTITION_HIVE),
    ] {
        if v.get(field).is_some() {
            flags.set(flag, b::boolean(v, field)?);
        }
    }
    Ok(lazy.with_optimizations(flags))
}

fn validate_aggregate_fields(v: &Value) -> Result<()> {
    let op = b::string(v, "op")?;
    match op {
        "std" | "variance" => aggregate_options(v, &["ddof"]),
        "quantile" => aggregate_options(v, &["quantile", "interpolation"]),
        "mode" => aggregate_options(v, &["maintainOrder"]),
        "skew" => aggregate_options(v, &["bias"]),
        "kurtosis" => aggregate_options(v, &["fisher", "bias"]),
        "any" | "all" => aggregate_options(v, &["ignoreNulls"]),
        _ => aggregate_options(v, &[]),
    }
}

fn aggregate_options(v: &Value, options: &[&str]) -> Result<()> {
    for key in [
        "ddof",
        "quantile",
        "interpolation",
        "maintainOrder",
        "bias",
        "fisher",
        "ignoreNulls",
    ] {
        if v.get(key).is_some() && !options.contains(&key) {
            return Err(EngineError::Invalid("irrelevant aggregate option".into()));
        }
    }
    Ok(())
}
fn validate_lazy_fields(v: &Value, c: &str) -> Result<()> {
    let f: &[&str] = match c {
        "lazySelect" => &["input", "expressions"],
        "lazyFilter" => &["input", "predicate"],
        "lazyWithColumns" => &["input", "expressions"],
        "lazySort" => &["input", "by", "descending", "nullsLast", "maintainOrder"],
        "lazySlice" => &["input", "offset", "length"],
        "lazyGroupBy" => &["input", "keys", "aggregations", "maintainOrder"],
        "lazyJoin" => &[
            "left",
            "right",
            "leftOn",
            "rightOn",
            "how",
            "suffix",
            "coalesce",
            "nullsEqual",
            "validation",
            "maintainOrder",
            "allowParallel",
            "forceParallel",
        ],
        "lazyJoinAsOf" => &[
            "left",
            "right",
            "leftOn",
            "rightOn",
            "strategy",
            "tolerance",
            "leftBy",
            "rightBy",
            "allowEqual",
            "checkSortedness",
            "suffix",
            "coalesce",
            "allowParallel",
            "forceParallel",
        ],
        "lazyJoinWhere" => &[
            "left",
            "right",
            "predicates",
            "suffix",
            "allowParallel",
            "forceParallel",
        ],
        "lazyGroupByDynamic" => &[
            "input",
            "indexColumn",
            "groupBy",
            "aggregations",
            "every",
            "period",
            "offset",
            "closed",
            "label",
            "includeBoundaries",
            "startBy",
        ],
        "lazyGroupByRolling" => &[
            "input",
            "indexColumn",
            "groupBy",
            "aggregations",
            "period",
            "offset",
            "closed",
        ],
        "lazyDistinct" => &["input", "subset", "keep", "maintainOrder"],
        "lazyDropNulls" => &["input", "subset"],
        "lazyDrop" => &["input", "columns", "strict"],
        "lazyRename" => &["input", "existing", "new", "strict"],
        "lazyExplode" => &["input", "columns", "emptyAsNull", "keepNulls"],
        "lazyUnnest" => &["input", "columns"],
        "lazyUnpivot" => &["input", "on", "index", "variableName", "valueName"],
        "lazyConcat" => &["inputs", "how", "rechunk"],
        _ => return Err(EngineError::Invalid(format!("unknown command '{c}'"))),
    };
    fields(v, f)
}

fn path(v: &Value) -> Result<&str> {
    let p = b::string(v, "path")?;
    if p.len() > 1_048_576 {
        return Err(EngineError::Invalid("invalid path length".into()));
    }
    Ok(p)
}
fn string_opt<'a>(v: &'a Value, key: &str) -> Result<Option<&'a str>> {
    v.get(key)
        .map(|x| {
            x.as_str()
                .ok_or_else(|| EngineError::Invalid(format!("'{key}' must be a string")))
        })
        .transpose()
}
fn bool_opt(v: &Value, key: &str) -> Result<Option<bool>> {
    v.get(key)
        .map(|x| {
            x.as_bool()
                .ok_or_else(|| EngineError::Invalid(format!("'{key}' must be a boolean")))
        })
        .transpose()
}
fn usize_value_opt(v: &Value, key: &str) -> Result<Option<usize>> {
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
fn positive_usize_opt(v: &Value, key: &str) -> Result<Option<usize>> {
    let value = usize_value_opt(v, key)?;
    if value == Some(0) {
        return Err(EngineError::Invalid(format!("'{key}' must be positive")));
    }
    Ok(value)
}
fn nonzero(v: &Value, key: &str, default: usize) -> Result<NonZeroUsize> {
    NonZeroUsize::new(usize_value_opt(v, key)?.unwrap_or(default))
        .ok_or_else(|| EngineError::Invalid(format!("'{key}' must be positive")))
}
fn byte(v: &Value, key: &str, default: u8) -> Result<u8> {
    match string_opt(v, key)? {
        None => Ok(default),
        Some(value) if value.as_bytes().len() == 1 => Ok(value.as_bytes()[0]),
        Some(_) => Err(EngineError::Invalid(format!("'{key}' must be one byte"))),
    }
}
fn optional_string<'a>(v: &'a Value, key: &str, default: &'a str) -> Result<&'a str> {
    string_opt(v, key).map(|x| x.unwrap_or(default))
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
fn write_csv(v: &Value) -> Result<Value> {
    let mut df = registry::frame(b::handle(v, "frame")?)?;
    let p = path(v)?;
    let sep = v
        .get("separator")
        .map(|x| {
            x.as_str()
                .ok_or_else(|| EngineError::Invalid("separator must be a string".into()))
        })
        .transpose()?
        .unwrap_or(",");
    if sep.len() != 1 {
        return Err(EngineError::Invalid("separator must be one byte".into()));
    }
    let mut f = temporary(p)?;
    let quote_style = match optional_string(v, "quoteStyle", "necessary")? {
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
    let mut writer = CsvWriter::new(f.as_file_mut())
        .include_header(b::optional_bool(v, "includeHeader", true)?)
        .include_bom(b::optional_bool(v, "includeBom", false)?)
        .with_separator(sep.as_bytes()[0])
        .with_batch_size(nonzero(v, "batchSize", 1024)?)
        .with_date_format(string_opt(v, "dateFormat")?.map(Into::into))
        .with_time_format(string_opt(v, "timeFormat")?.map(Into::into))
        .with_datetime_format(string_opt(v, "datetimeFormat")?.map(Into::into))
        .with_float_scientific(bool_opt(v, "floatScientific")?)
        .with_float_precision(usize_value_opt(v, "floatPrecision")?)
        .with_decimal_comma(b::optional_bool(v, "decimalComma", false)?)
        .with_quote_char(byte(v, "quoteChar", b'"')?)
        .with_null_value(optional_string(v, "nullValue", "")?.into())
        .with_line_terminator(optional_string(v, "lineTerminator", "\n")?.into())
        .with_quote_style(quote_style);
    if let Some(n_threads) = usize_value_opt(v, "nThreads")? {
        if n_threads == 0 {
            return Err(EngineError::Invalid("'nThreads' must be positive".into()));
        }
        writer = writer.n_threads(n_threads);
    }
    writer.finish(&mut df)?;
    persist(f, p)?;
    Ok(json!({"path":p}))
}
fn write_parquet(v: &Value) -> Result<Value> {
    let mut df = registry::frame(b::handle(v, "frame")?)?;
    let p = path(v)?;
    let compression = match v
        .get("compression")
        .map(|x| {
            x.as_str()
                .ok_or_else(|| EngineError::Invalid("compression must be a string".into()))
        })
        .transpose()?
        .unwrap_or("zstd")
    {
        "none" | "uncompressed" => ParquetCompression::Uncompressed,
        "snappy" => ParquetCompression::Snappy,
        "gzip" => ParquetCompression::Gzip(None),
        "brotli" => ParquetCompression::Brotli(None),
        "zstd" => ParquetCompression::Zstd(None),
        "lz4" | "lz4raw" => ParquetCompression::Lz4Raw,
        x => {
            return Err(EngineError::Unsupported(format!(
                "Parquet compression '{x}'"
            )))
        }
    };
    let mut f = temporary(p)?;
    ParquetWriter::new(f.as_file_mut())
        .with_compression(compression)
        .with_statistics(parquet_statistics(v)?)
        .with_row_group_size(positive_usize_opt(v, "rowGroupSize")?)
        .with_data_page_size(positive_usize_opt(v, "dataPageSize")?)
        .set_parallel(b::optional_bool(v, "parallel", true)?)
        .finish(&mut df)?;
    persist(f, p)?;
    Ok(json!({"path":p}))
}

fn hello() -> Value {
    const DATATYPES: [&str; 31] = [
        "null",
        "boolean",
        "uint8",
        "uint16",
        "uint32",
        "uint64",
        "uint128",
        "int8",
        "int16",
        "int32",
        "int64",
        "int128",
        "float16",
        "float32",
        "float64",
        "decimal",
        "string",
        "binary",
        "binaryOffset",
        "date",
        "datetime",
        "duration",
        "time",
        "array",
        "list",
        "object",
        "categorical",
        "enum",
        "struct",
        "extension",
        "unknown",
    ];
    let datatype_capabilities = DATATYPES
        .iter()
        .map(|kind| {
            let copied = DATATYPES[..23].contains(kind);
            let namespace_kernel =
                ["array", "list", "categorical", "enum", "struct"].contains(kind);
            json!({
                "kind": kind,
                "descriptor": true,
                "literal": copied,
                "import": copied,
                "export": copied,
                "cast": copied || *kind == "enum",
                "kernels": copied || namespace_kernel,
            })
        })
        .collect::<Vec<_>>();
    json!({
        "abi": crate::ABI_VERSION,
        "protocol": 2,
        "polars": "0.55.2",
        "datatypes": DATATYPES,
        "datatypeCapabilities": datatype_capabilities,
        "resources": ["expr", "selector", "dtypeSelector", "lazyFrame", "frame", "series", "job", "sqlContext", "batchStream", "databaseConnection"],
        "interchange": {
            "arrowCDataVersion": 1,
            "arrowCStreamVersion": 1,
            "ownership": "imports-consume-top-level-structs-always; exports-independent; release-exactly-once",
            "types": "flat",
            "dataTypes": ["null", "boolean", "int8", "int16", "int32", "int64", "uint8", "uint16", "uint32", "uint64", "float16", "float32", "float64", "string", "largeString", "stringView", "binary", "largeBinary", "binaryView", "date32", "date64", "time32", "time64", "timestamp", "duration", "decimal"],
            "dictionary": false,
            "nested": false,
            "frameRepresentation": "struct-with-flat-children",
            "frameTopLevelValidity": false,
            "zeroColumnFrames": true,
            "streamImportLimitsRequired": true,
            "unknownNullCount": false,
            "symbols": ["df_arrow_array_new", "df_arrow_schema_new", "df_arrow_stream_new", "df_arrow_array_delete", "df_arrow_schema_delete", "df_arrow_stream_delete", "df_series_export_arrow", "df_series_import_arrow", "df_frame_export_arrow", "df_frame_import_arrow", "df_frame_export_arrow_stream", "df_frame_import_arrow_stream"]
        },
        "commands": {
            "core": ["hello", "runtimeDiagnostics"],
            "frame": ["frameImport", "frameInfo", "frameExport", "frameLazy", "frameReadJson", "frameReadIpcStream", "frameWriteCsv", "frameWriteParquet", "frameWriteIpc", "frameWriteIpcStream", "frameWriteJson", "frameWriteNdjson", "frameColumn", "frameSelectColumns", "frameSelect", "frameFilter", "frameFilterMask", "frameWithColumns", "frameSort", "frameSlice", "frameReverse", "frameDistinct", "frameDropNulls", "frameExplode", "frameUnnest", "frameUnpivot", "frameTranspose", "frameDrop", "frameRename"],
            "series": ["seriesImport", "seriesInfo", "seriesExport", "seriesToFrame", "seriesRename", "seriesCast", "seriesSlice", "seriesReverse", "seriesSort", "seriesFilter", "seriesDropNulls", "seriesAppend", "seriesGather", "seriesUnique", "seriesBinary", "seriesAggregate"],
            "job": ["lazyCollect", "lazySubmit", "lazyProfile", "jobPoll", "jobCancel", "jobTake", "lazyBatchStream", "batchStreamPoll", "batchStreamCancel"],
            "expression": ["exprColumn", "exprLiteral", "exprLen", "exprAlias", "exprCast", "exprUnary", "exprBinary", "exprTernary", "exprAggregate", "exprFunction", "exprMeta", "exprOver"],
            "selector": ["selectorAll", "selectorEmpty", "selectorByName", "selectorByIndex", "selectorMatches", "selectorBinary", "selectorNot", "selectorAsExpr"],
            "dtypeSelector": ["dtypeSelectorCreate", "dtypeSelectorBinary", "dtypeSelectorNot", "dtypeSelectorAsSelector", "dtypeSelectorMatches"],
            "sql": ["sqlContextNew", "sqlContextRegister", "sqlContextRegisterAll", "sqlContextUnregister", "sqlContextTables", "sqlContextExecute"],
            "database": ["databaseConnectionOpenSqlite", "databaseConnectionQuery", "databaseConnectionExecute", "databaseConnectionWriteFrame"],
            "lazy": ["lazyScanCsv", "lazyScanParquet", "lazyScanIpc", "lazyScanNdjson", "lazySinkCsv", "lazySinkParquet", "lazySinkIpc", "lazySinkNdjson", "lazySelect", "lazySelectInputs", "lazyFilter", "lazyWithColumns", "lazyWithColumnsInputs", "lazySort", "lazySlice", "lazyGroupBy", "lazyGroupByDynamic", "lazyGroupByRolling", "lazyJoin", "lazyJoinAsOf", "lazyJoinWhere", "lazyDistinct", "lazyDropNulls", "lazyDrop", "lazyRename", "lazyExplode", "lazyUnnest", "lazyUnpivot", "lazyConcat", "lazySchema", "lazyExplain"]
        },
        "operations": {
            "unary": ["not", "negate", "neg", "isNull", "isNotNull", "isNan", "isNotNan"],
            "binary": ["eq", "eqValidity", "notEq", "notEqValidity", "lt", "ltEq", "gt", "gtEq", "add", "subtract", "multiply", "trueDivide", "floorDivide", "modulo", "bitAnd", "bitOr", "bitXor", "logicalAnd", "logicalOr"],
            "seriesBinary": ["eq", "eqValidity", "notEq", "notEqValidity", "lt", "ltEq", "gt", "gtEq", "add", "subtract", "multiply", "trueDivide"],
            "seriesAggregate": ["count", "nUnique", "sum", "mean", "min", "max", "first", "last"],
            "selectorAlgebra": ["union", "intersection", "symmetricDifference", "difference", "complement"],
            "selectorKinds": ["all", "empty", "byName", "byIndex", "matches", "byDType"],
            "dtypeSelectorKinds": ["all", "empty", "anyOf", "integer", "unsignedInteger", "signedInteger", "floating", "enum", "categorical", "nested", "list", "array", "struct", "decimal", "numeric", "temporal", "datetime", "duration", "object"],
            "aggregate": ["count", "nullCount", "sum", "mean", "min", "max", "first", "last", "median", "nUnique", "product", "std", "variance", "quantile", "argMin", "argMax", "approximateNUnique", "nanMin", "nanMax", "mode", "skew", "kurtosis", "any", "all"],
            "functions": ["isNull", "isNotNull", "isNan", "isNotNan", "fillNull", "abs", "floor", "ceil", "round", "clip", "clipMin", "clipMax", "fillNan", "isFinite", "isInfinite", "coalesce", "isIn", "lowercase", "uppercase", "stringContains", "stringStartsWith", "stringEndsWith", "stringReplace", "stripChars", "shift", "cumSum", "cumMin", "cumMax", "pow", "sqrt", "cbrt", "log", "log1p", "exp", "sin", "cos", "tan", "cot", "asin", "acos", "atan", "atan2", "sinh", "cosh", "tanh", "asinh", "acosh", "atanh", "degrees", "radians", "rank", "interpolate", "interpolateBy", "diff", "pctChange", "rollingMin", "rollingMax", "rollingMean", "rollingSum", "rollingMedian", "rollingVariance", "rollingStd", "ewmMean", "ewmSum", "ewmStd", "ewmVariance"],
            "qualifiedFunctions": ["str.lenBytes", "str.lenChars", "str.toLowercase", "str.toUppercase", "str.contains", "str.startsWith", "str.endsWith", "str.find", "str.extract", "str.extractAll", "str.split", "str.replace", "str.stripChars", "str.stripCharsStart", "str.stripCharsEnd", "str.stripPrefix", "str.stripSuffix", "str.slice", "str.head", "str.tail", "str.padStart", "str.padEnd", "str.zfill", "str.toDate", "str.toTime", "str.toDatetime", "dt.year", "dt.isoYear", "dt.month", "dt.day", "dt.ordinalDay", "dt.weekday", "dt.week", "dt.quarter", "dt.hour", "dt.minute", "dt.second", "dt.millisecond", "dt.microsecond", "dt.nanosecond", "dt.date", "dt.time", "dt.timestamp", "dt.format", "dt.truncate", "dt.round", "dt.offsetBy", "dt.convertTimeZone", "dt.baseUtcOffset", "dt.dstOffset", "list.len", "list.first", "list.last", "list.sum", "list.min", "list.max", "list.mean", "list.get", "list.contains", "list.sort", "list.slice", "arr.len", "arr.sum", "arr.min", "arr.max", "arr.mean", "arr.toList", "arr.get", "arr.contains", "arr.sort", "arr.explode", "struct.field", "struct.fieldAt", "struct.renameFields", "struct.jsonEncode", "bin.sizeBytes", "bin.contains", "bin.startsWith", "bin.endsWith", "bin.hexEncode", "bin.base64Encode", "cat.physical", "cat.categories", "name.keep", "name.prefix", "name.suffix", "name.toLowercase", "name.toUppercase", "meta.undoAliases"],
            "expressionMetadata": ["rootNames", "outputName", "isColumn", "isColumnSelection", "isLiteral", "hasMultipleOutputs", "isRegexProjection"],
            "options": {
                "sqlite": ["bundled", "localFilesystemOnly", "positionalScalarParameters", "ifExists=fail|replace|append", "maxParameters=10000", "maxQueryRows=10000000"],
                "cast": ["strict"],
                "std": ["ddof"], "variance": ["ddof"],
                "quantile": ["quantile", "interpolation=nearest|lower|higher|midpoint|linear"],
                "mode": ["maintainOrder"], "skew": ["bias"],
                "kurtosis": ["fisher", "bias"], "any": ["ignoreNulls"], "all": ["ignoreNulls"],
                "function": ["arguments"],
                "round": ["decimals", "mode=halfToEven|halfAwayFromZero|toZero"],
                "isIn": ["nullsEqual"],
                "stringContains": ["literal", "strict"],
                "stringReplace": ["literal", "replaceAll"],
                "cumSum": ["reverse"], "cumMin": ["reverse"], "cumMax": ["reverse"],
                "rank": ["method=average|min|max|dense|ordinal", "descending"],
                "interpolate": ["method=linear|nearest"], "diff": ["nullBehavior=ignore|drop"],
                "rollingMin": ["windowSize", "minPeriods", "weights", "center"],
                "rollingMax": ["windowSize", "minPeriods", "weights", "center"],
                "rollingMean": ["windowSize", "minPeriods", "weights", "center"],
                "rollingSum": ["windowSize", "minPeriods", "weights", "center"],
                "rollingMedian": ["windowSize", "minPeriods", "weights", "center"],
                "rollingVariance": ["windowSize", "minPeriods", "weights", "center"],
                "rollingStd": ["windowSize", "minPeriods", "weights", "center"],
                "ewmMean": ["alpha", "adjust", "minPeriods", "ignoreNulls"],
                "ewmSum": ["alpha", "minPeriods", "ignoreNulls"],
                "ewmStd": ["alpha", "adjust", "bias", "minPeriods", "ignoreNulls"],
                "ewmVariance": ["alpha", "adjust", "bias", "minPeriods", "ignoreNulls"],
                "select": ["expressions"], "filter": ["predicate"], "withColumns": ["expressions"],
                "sort": ["by", "descending", "nullsLast", "maintainOrder"],
                "slice": ["offset", "length"],
                "groupBy": ["keys", "aggregations", "maintainOrder"],
                "groupByDynamic": ["indexColumn", "groupBy", "aggregations", "every", "period", "offset", "closed=left|right|both|none", "label=left|right|dataPoint", "includeBoundaries", "startBy"],
                "groupByRolling": ["indexColumn", "groupBy", "aggregations", "period", "offset", "closed=left|right|both|none"],
                "join": ["leftOn", "rightOn", "how=inner|left|right|full|outer|semi|anti|cross", "suffix", "coalesce", "nullsEqual", "validation", "maintainOrder", "allowParallel", "forceParallel"],
                "joinAsOf": ["leftOn", "rightOn", "strategy=backward|forward|nearest", "tolerance", "leftBy", "rightBy", "allowEqual", "checkSortedness", "suffix", "coalesce", "allowParallel", "forceParallel"],
                "joinWhere": ["predicates", "suffix", "allowParallel", "forceParallel"],
                "distinct": ["subset", "keep=first|last|any|none", "maintainOrder"],
                "concat": ["inputs", "how=vertical|verticalRelaxed|diagonal|diagonalRelaxed|horizontal", "rechunk"],
                "dropNulls": ["subset"], "drop": ["columns", "strict"],
                "rename": ["existing", "new", "strict"],
                "explode": ["columns", "emptyAsNull=true", "keepNulls=true"],
                "unnest": ["columns"], "unpivot": ["on", "index", "variableName", "valueName"],
                "transpose": ["includeHeader", "headerName", "columnNames"],
                "over": ["partitionBy", "orderBy", "mapping=groupsToRows|explode|join", "orderDescending", "orderNullsLast", "orderMaintainOrder", "orderMultithreaded"],
                "scanCsv": ["path", "hasHeader", "separator", "skipRows", "nRows", "tryParseDates"],
                "scanParquet": ["path", "nRows", "parallel"],
                "writeCsv": ["path", "includeHeader", "separator", "includeBom", "batchSize", "dateFormat", "timeFormat", "datetimeFormat", "floatScientific", "floatPrecision", "decimalComma", "quoteChar", "nullValue", "lineTerminator", "quoteStyle=necessary|always|nonNumeric|never", "nThreads=eagerOnly"],
                "writeParquet": ["path", "compression=none|uncompressed|snappy|gzip|brotli|zstd|lz4|lz4raw", "rowGroupSize", "dataPageSize", "statisticsMin", "statisticsMax", "statisticsDistinctCount", "statisticsNullCount", "statisticsBinaryTruncateLength", "parallel=eagerOnly"],
                "scanIpc": ["path", "nRows", "cache", "rechunk", "recordBatchStatistics"],
                "scanNdjson": ["path", "nRows", "inferSchemaLength", "ignoreErrors", "lowMemory", "rechunk"],
                "readJson": ["path", "inferSchemaLength", "batchSize", "rechunk"],
                "readIpcStream": ["path", "nRows", "columns", "rechunk"],
                "writeIpc": ["path", "compression=none|lz4|zstd", "recordBatchSize", "parallel", "recordBatchStatistics"],
                "writeIpcStream": ["path", "compression=none|lz4|zstd"],
                "writeJson": ["path", "format=json"],
                "writeNdjson": ["path", "format=jsonLines"],
                "sink": ["path", "maintainOrder", "nativeStreamingExecution"]
            },
            "executionEngines": ["auto", "in-memory", "streaming"],
            "asyncJobEngines": ["auto"],
            "maxActiveJobs": 64,
            "optimizerFlags": ["projectionPushdown", "predicatePushdown", "clusterWithColumns", "typeCoercion", "simplifyExpression", "typeCheck", "slicePushdown", "commonSubplanElimination", "commonSubexpressionElimination", "rowEstimate", "fastProjection", "checkOrderObserve", "sortCollapse", "partitionHive"],
            "explainFormats": ["plain", "tree", "dot"],
            "profileTimingUnit": "microseconds"
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn call(v: Value) -> Result<Value> {
        invoke(&serde_json::to_vec(&v).unwrap())
    }
    fn command(name: &str, mut fields: serde_json::Map<String, Value>) -> Result<Value> {
        fields.insert("protocol".into(), json!(2));
        fields.insert("command".into(), json!(name));
        call(Value::Object(fields))
    }
    fn h(v: &Value) -> String {
        v["handle"].as_str().unwrap().to_owned()
    }
    #[test]
    fn protocol_two_chain_branches_and_jobs() {
        assert_eq!(
            call(json!({"protocol":2,"command":"hello"})).unwrap()["protocol"],
            2
        );
        assert!(call(json!({"protocol":1,"command":"hello"})).is_err());
        let frame=call(json!({"protocol":2,"command":"frameImport","batch":{"columns":[{"name":"a","dtype":{"kind":"int32"},"values":[1,2,3]}]}})).unwrap();
        let lazy = call(json!({"protocol":2,"command":"frameLazy","frame":h(&frame)})).unwrap();
        let column = call(json!({"protocol":2,"command":"exprColumn","name":"a"})).unwrap();
        let one=call(json!({"protocol":2,"command":"exprLiteral","scalar":{"dtype":{"kind":"int32"},"value":1}})).unwrap();
        let gt=call(json!({"protocol":2,"command":"exprBinary","left":h(&column),"right":h(&one),"op":"gt"})).unwrap();
        let filtered =
            call(json!({"protocol":2,"command":"lazyFilter","input":h(&lazy),"predicate":h(&gt)}))
                .unwrap();
        registry::release(h(&lazy).parse().unwrap()).unwrap();
        let selected=call(json!({"protocol":2,"command":"lazySelect","input":h(&filtered),"expressions":[h(&column)]})).unwrap();
        let schema =
            call(json!({"protocol":2,"command":"lazySchema","input":h(&selected)})).unwrap();
        assert_eq!(schema["schema"][0]["name"], "a");
        assert!(call(
            json!({"protocol":2,"command":"lazyExplain","input":h(&selected),"optimized":true})
        )
        .unwrap()["explanation"]
            .as_str()
            .unwrap()
            .contains("FILTER"));
        let job = call(json!({"protocol":2,"command":"lazySubmit","input":h(&selected)})).unwrap();
        loop {
            let taken = call(json!({"protocol":2,"command":"jobTake","job":h(&job)})).unwrap();
            if taken["ready"] == true {
                let info =
                    call(json!({"protocol":2,"command":"frameInfo","frame":h(&taken)})).unwrap();
                assert_eq!(info["height"], 2);
                break;
            }
        }
    }
    #[test]
    fn schemas_are_closed_and_handles_are_strings() {
        assert!(call(json!({"protocol":2,"command":"hello","oldGraph":[]})).is_err());
        assert!(call(json!({"protocol":2,"command":"frameInfo","frame":1})).is_err());
        assert!(call(json!({"protocol":2,"command":"execute"})).is_err());
        let _ = command("hello", serde_json::Map::new()).unwrap();
    }

    #[test]
    fn hello_is_complete_and_operation_registry_is_truthful() {
        let value = hello();
        assert_eq!(value["datatypes"].as_array().unwrap().len(), 31);
        assert_eq!(value["datatypeCapabilities"].as_array().unwrap().len(), 31);
        assert_eq!(
            value["resources"],
            json!([
                "expr",
                "selector",
                "dtypeSelector",
                "lazyFrame",
                "frame",
                "series",
                "job",
                "sqlContext",
                "batchStream",
                "databaseConnection"
            ])
        );
        let command_count: usize = value["commands"]
            .as_object()
            .unwrap()
            .values()
            .map(|commands| commands.as_array().unwrap().len())
            .sum();
        assert_eq!(command_count, 122);
        assert!(value["commands"]["expression"]
            .as_array()
            .unwrap()
            .contains(&json!("exprLen")));
        assert!(!value["operations"]["aggregate"]
            .as_array()
            .unwrap()
            .contains(&json!("len")));
        for option in [
            "cast",
            "std",
            "variance",
            "quantile",
            "round",
            "sort",
            "groupBy",
            "groupByDynamic",
            "groupByRolling",
            "join",
            "joinAsOf",
            "joinWhere",
            "distinct",
            "concat",
            "dropNulls",
            "drop",
            "rename",
            "explode",
            "unnest",
            "unpivot",
            "transpose",
            "over",
            "scanCsv",
            "scanParquet",
            "writeCsv",
            "writeParquet",
        ] {
            assert!(
                value["operations"]["options"].get(option).is_some(),
                "{option}"
            );
        }
    }

    #[test]
    fn null_import_and_cross_join_keys_are_strict() {
        assert!(call(json!({
            "protocol":2, "command":"frameImport",
            "batch":{"columns":[{"name":"n","dtype":{"kind":"null"},"values":[null,1]}]}
        }))
        .is_err());

        let left = registry::insert(Entry::LazyFrame(Box::new(
            df!("key" => [1_i32]).unwrap().lazy(),
        )))
        .unwrap();
        let right = registry::insert(Entry::LazyFrame(Box::new(
            df!("key" => [2_i32]).unwrap().lazy(),
        )))
        .unwrap();
        let key = registry::insert(Entry::Expr(col("key"))).unwrap();
        assert!(call(json!({
            "protocol":2, "command":"lazyJoin", "left":left.to_string(),
            "right":right.to_string(), "leftOn":[key.to_string()], "rightOn":[],
            "how":"cross"
        }))
        .is_err());
        registry::release(left).unwrap();
        registry::release(right).unwrap();
        registry::release(key).unwrap();
    }

    #[test]
    fn native_seeded_nested_columns_explode_then_unnest() {
        let items = Series::new(
            "items".into(),
            &[
                Series::new("".into(), [1_i32, 2]),
                Series::new("".into(), [3_i32]),
            ],
        );
        let records = df!("name" => ["a", "b"], "score" => [10_i32, 20])
            .unwrap()
            .into_struct("record".into())
            .into_series();
        let frame = DataFrame::new(2, vec![items.into(), records.into()]).unwrap();
        let input = registry::insert(Entry::LazyFrame(Box::new(frame.lazy()))).unwrap();
        let exploded = call(json!({
            "protocol":2, "command":"lazyExplode", "input":input.to_string(),
            "columns":["items"], "emptyAsNull":true, "keepNulls":true
        }))
        .unwrap();
        let unnested = call(json!({
            "protocol":2, "command":"lazyUnnest", "input":h(&exploded),
            "columns":["record"]
        }))
        .unwrap();
        let output = registry::lazy_frame(h(&unnested).parse().unwrap())
            .unwrap()
            .collect()
            .unwrap();
        assert_eq!(output.shape(), (3, 3));
        assert_eq!(output.get_column_names(), ["items", "name", "score"]);
        for handle in [
            input,
            h(&exploded).parse().unwrap(),
            h(&unnested).parse().unwrap(),
        ] {
            registry::release(handle).unwrap();
        }
    }
}
