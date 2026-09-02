use crate::{
    batch, bindings as b, dtype,
    error::{EngineError, Result},
    registry::{self, Entry},
};
use either::Either;
use polars::lazy::dsl::by_name;
use polars::prelude::*;
use serde_json::{json, Value};

const LEFT: &str = "__dartaframes_left";
const RIGHT: &str = "__dartaframes_right";
const RESULT: &str = "__dartaframes_result";

fn fields(v: &Value, extra: &[&str]) -> Result<()> {
    let mut allowed = vec!["protocol", "command"];
    allowed.extend(extra);
    b::validate_fields(v, &allowed)
}

fn response(entry: Entry, kind: &str) -> Result<Value> {
    let handle = registry::insert(entry)?;
    Ok(json!({"handle":handle.to_string(),"kind":kind}))
}

fn series_response(series: Series) -> Result<Value> {
    response(Entry::Series(series), "series")
}

fn frame_response(frame: DataFrame) -> Result<Value> {
    response(Entry::Frame(frame), "frame")
}

fn length(v: &Value, key: &str) -> Result<usize> {
    let value = b::req(v, key)?
        .as_u64()
        .ok_or_else(|| EngineError::Invalid(format!("'{key}' must be unsigned")))?;
    usize::try_from(value).map_err(|_| EngineError::Invalid(format!("'{key}' is too large")))
}

fn bools(v: &Value, key: &str, len: usize) -> Result<Vec<bool>> {
    let values = b::req(v, key)?
        .as_array()
        .ok_or_else(|| EngineError::Invalid(format!("'{key}' must be an array")))?;
    if values.len() != len {
        return Err(EngineError::Invalid(format!(
            "'{key}' length must match expressions"
        )));
    }
    values
        .iter()
        .map(|value| {
            value
                .as_bool()
                .ok_or_else(|| EngineError::Invalid(format!("'{key}' values must be booleans")))
        })
        .collect()
}

fn optional_string<'a>(v: &'a Value, key: &str, default: &'a str) -> Result<&'a str> {
    match v.get(key) {
        None => Ok(default),
        Some(value) => value
            .as_str()
            .ok_or_else(|| EngineError::Invalid(format!("'{key}' must be a string"))),
    }
}

fn optional_names(v: &Value, key: &str) -> Result<Option<Vec<String>>> {
    v.get(key)
        .map(|_| {
            b::names(v, key).map(|names| names.into_iter().map(|name| name.to_string()).collect())
        })
        .transpose()
}

fn renamed(mut series: Series, name: &str) -> Series {
    series.rename(name.into());
    series
}

fn evaluate_unary(series: Series, expression: Expr) -> Result<Series> {
    let name = series.name().clone();
    let frame = renamed(series, LEFT).into_frame();
    let output = frame.lazy().select([expression.alias(RESULT)]).collect()?;
    Ok(renamed(
        output.column(RESULT)?.as_materialized_series().clone(),
        name.as_str(),
    ))
}

fn binary_expression(left: Expr, right: Expr, op: &str) -> Result<Expr> {
    Ok(match op {
        "eq" => left.eq(right),
        "eqValidity" => left.eq_missing(right),
        "notEq" => left.neq(right),
        "notEqValidity" => left.neq_missing(right),
        "lt" => left.lt(right),
        "ltEq" => left.lt_eq(right),
        "gt" => left.gt(right),
        "gtEq" => left.gt_eq(right),
        "add" => left + right,
        "subtract" => left - right,
        "multiply" => left * right,
        "trueDivide" => left.true_div(right),
        other => {
            return Err(EngineError::Unsupported(format!(
                "series binary operation '{other}'"
            )))
        }
    })
}

fn binary(v: &Value) -> Result<Series> {
    let has_right = v.get("right").is_some();
    let has_scalar = v.get("scalar").is_some();
    if has_right == has_scalar {
        return Err(EngineError::Invalid(
            "seriesBinary requires exactly one of 'right' and 'scalar'".into(),
        ));
    }
    let left = registry::series(b::handle(v, "left")?)?;
    let original_name = left.name().clone();
    let left = renamed(left, LEFT);
    let right_expr;
    let frame = if has_right {
        let right = renamed(registry::series(b::handle(v, "right")?)?, RIGHT);
        right_expr = col(RIGHT);
        DataFrame::new(left.len(), vec![left.into(), right.into()])?
    } else {
        right_expr = b::literal(b::req(v, "scalar")?)?;
        left.into_frame()
    };
    let expression = binary_expression(col(LEFT), right_expr, b::string(v, "op")?)?;
    let output = frame.lazy().select([expression.alias(RESULT)]).collect()?;
    Ok(renamed(
        output.column(RESULT)?.as_materialized_series().clone(),
        original_name.as_str(),
    ))
}

fn scalar_json(series: Series) -> Result<Value> {
    let exported = batch::export(&series.into_frame())?;
    let column = &exported["columns"][0];
    let dtype = column["dtype"].clone();
    let value = column["values"][0].clone();
    let mut scalar = json!({"dtype":dtype});
    if let (Some(target), Some(payload)) = (scalar.as_object_mut(), value.as_object()) {
        target.extend(payload.clone());
    } else {
        scalar["value"] = value;
    }
    Ok(scalar)
}

fn aggregate(v: &Value) -> Result<Value> {
    let series = registry::series(b::handle(v, "series")?)?;
    let op = b::string(v, "op")?;
    match op {
        "count" => return Ok(json!({"value":series.len() - series.null_count()})),
        "nUnique" => return Ok(json!({"value":series.n_unique()?})),
        _ => {}
    }
    let expression = match op {
        "sum" => col(LEFT).sum(),
        "mean" => col(LEFT).mean(),
        "min" => col(LEFT).min(),
        "max" => col(LEFT).max(),
        "first" => col(LEFT).first(),
        "last" => col(LEFT).last(),
        other => {
            return Err(EngineError::Unsupported(format!(
                "series aggregate '{other}'"
            )))
        }
    };
    let result = evaluate_unary(series, expression)?;
    Ok(json!({"scalar":scalar_json(result)?}))
}

pub fn dispatch(command: &str, v: &Value) -> Result<Option<Value>> {
    let output = match command {
        "seriesImport" => {
            fields(v, &["column"])?;
            let frame = batch::import(&json!({"columns":[b::req(v, "column")?]}))?;
            let series = frame
                .columns()
                .first()
                .ok_or_else(|| EngineError::Invalid("series column is missing".into()))?
                .as_materialized_series()
                .clone();
            series_response(series)?
        }
        "seriesInfo" => {
            fields(v, &["series"])?;
            let series = registry::series(b::handle(v, "series")?)?;
            json!({
                "name":series.name().as_str(),
                "dtype":dtype::descriptor(series.dtype()),
                "length":series.len(),
                "nullCount":series.null_count(),
                "chunkCount":series.n_chunks(),
            })
        }
        "seriesExport" => {
            fields(v, &["series"])?;
            let exported = batch::export(&registry::series(b::handle(v, "series")?)?.into_frame())?;
            json!({"column":exported["columns"][0].clone()})
        }
        "seriesToFrame" => {
            fields(v, &["series"])?;
            frame_response(registry::series(b::handle(v, "series")?)?.into_frame())?
        }
        "seriesRename" => {
            fields(v, &["series", "name"])?;
            let mut series = registry::series(b::handle(v, "series")?)?;
            series.rename(b::string(v, "name")?.into());
            series_response(series)?
        }
        "seriesCast" => {
            fields(v, &["series", "dtype", "strict"])?;
            let series = registry::series(b::handle(v, "series")?)?;
            let target = dtype::parse(b::req(v, "dtype")?)?;
            let output = if b::optional_bool(v, "strict", true)? {
                series.strict_cast(&target)?
            } else {
                series.cast(&target)?
            };
            series_response(output)?
        }
        "seriesSlice" => {
            fields(v, &["series", "offset", "length"])?;
            let offset = b::req(v, "offset")?
                .as_i64()
                .ok_or_else(|| EngineError::Invalid("'offset' must be an integer".into()))?;
            series_response(
                registry::series(b::handle(v, "series")?)?.slice(offset, length(v, "length")?),
            )?
        }
        "seriesReverse" => {
            fields(v, &["series"])?;
            series_response(registry::series(b::handle(v, "series")?)?.reverse())?
        }
        "seriesSort" => {
            fields(
                v,
                &[
                    "series",
                    "descending",
                    "nullsLast",
                    "maintainOrder",
                    "multithreaded",
                ],
            )?;
            let options = SortOptions {
                descending: b::optional_bool(v, "descending", false)?,
                nulls_last: b::optional_bool(v, "nullsLast", false)?,
                maintain_order: b::optional_bool(v, "maintainOrder", false)?,
                multithreaded: b::optional_bool(v, "multithreaded", true)?,
                ..Default::default()
            };
            series_response(registry::series(b::handle(v, "series")?)?.sort(options)?)?
        }
        "seriesFilter" => {
            fields(v, &["series", "mask"])?;
            let series = registry::series(b::handle(v, "series")?)?;
            let mask = registry::series(b::handle(v, "mask")?)?;
            series_response(series.filter(mask.bool()?)?)?
        }
        "seriesDropNulls" => {
            fields(v, &["series"])?;
            series_response(registry::series(b::handle(v, "series")?)?.drop_nulls())?
        }
        "seriesAppend" => {
            fields(v, &["series", "other"])?;
            let mut series = registry::series(b::handle(v, "series")?)?;
            series.append(&registry::series(b::handle(v, "other")?)?)?;
            series_response(series)?
        }
        "seriesGather" => {
            fields(v, &["series", "indices"])?;
            let series = registry::series(b::handle(v, "series")?)?;
            let indices = registry::series(b::handle(v, "indices")?)?.strict_cast(&IDX_DTYPE)?;
            series_response(series.take(indices.idx()?)?)?
        }
        "seriesUnique" => {
            fields(v, &["series", "maintainOrder"])?;
            let series = registry::series(b::handle(v, "series")?)?;
            let output = if b::optional_bool(v, "maintainOrder", false)? {
                series.unique_stable()?
            } else {
                series.unique()?
            };
            series_response(output)?
        }
        "seriesBinary" => {
            fields(v, &["left", "right", "scalar", "op"])?;
            series_response(binary(v)?)?
        }
        "seriesAggregate" => {
            fields(v, &["series", "op"])?;
            aggregate(v)?
        }
        "frameColumn" => {
            fields(v, &["frame", "name"])?;
            let frame = registry::frame(b::handle(v, "frame")?)?;
            series_response(
                frame
                    .column(b::string(v, "name")?)?
                    .as_materialized_series()
                    .clone(),
            )?
        }
        "frameSelectColumns" => {
            fields(v, &["frame", "columns"])?;
            frame_response(
                registry::frame(b::handle(v, "frame")?)?.select(b::names(v, "columns")?)?,
            )?
        }
        "frameSelect" => {
            fields(v, &["frame", "expressions"])?;
            frame_response(
                registry::frame(b::handle(v, "frame")?)?
                    .lazy()
                    .select(b::exprs(v, "expressions")?)
                    .collect()?,
            )?
        }
        "frameFilter" => {
            fields(v, &["frame", "predicate"])?;
            frame_response(
                registry::frame(b::handle(v, "frame")?)?
                    .lazy()
                    .filter(registry::expr(b::handle(v, "predicate")?)?)
                    .collect()?,
            )?
        }
        "frameFilterMask" => {
            fields(v, &["frame", "mask"])?;
            let frame = registry::frame(b::handle(v, "frame")?)?;
            let mask = registry::series(b::handle(v, "mask")?)?;
            frame_response(frame.filter(mask.bool()?)?)?
        }
        "frameWithColumns" => {
            fields(v, &["frame", "expressions"])?;
            frame_response(
                registry::frame(b::handle(v, "frame")?)?
                    .lazy()
                    .with_columns(b::exprs(v, "expressions")?)
                    .collect()?,
            )?
        }
        "frameSort" => {
            fields(
                v,
                &["frame", "by", "descending", "nullsLast", "maintainOrder"],
            )?;
            let by = b::exprs(v, "by")?;
            if by.is_empty() {
                return Err(EngineError::Invalid("sort.by must not be empty".into()));
            }
            let n = by.len();
            let options = SortMultipleOptions::default()
                .with_order_descending_multi(bools(v, "descending", n)?)
                .with_nulls_last_multi(bools(v, "nullsLast", n)?)
                .with_maintain_order(b::optional_bool(v, "maintainOrder", false)?);
            frame_response(
                registry::frame(b::handle(v, "frame")?)?
                    .lazy()
                    .sort_by_exprs(by, options)
                    .collect()?,
            )?
        }
        "frameSlice" => {
            fields(v, &["frame", "offset", "length"])?;
            let offset = b::req(v, "offset")?
                .as_i64()
                .ok_or_else(|| EngineError::Invalid("'offset' must be an integer".into()))?;
            frame_response(
                registry::frame(b::handle(v, "frame")?)?.slice(offset, length(v, "length")?),
            )?
        }
        "frameReverse" => {
            fields(v, &["frame"])?;
            frame_response(registry::frame(b::handle(v, "frame")?)?.reverse())?
        }
        "frameDistinct" => {
            fields(v, &["frame", "subset", "keep", "maintainOrder"])?;
            let subset = optional_names(v, "subset")?;
            let keep = match optional_string(v, "keep", "first")? {
                "first" => UniqueKeepStrategy::First,
                "last" => UniqueKeepStrategy::Last,
                "any" => UniqueKeepStrategy::Any,
                "none" => UniqueKeepStrategy::None,
                value => return Err(EngineError::Invalid(format!("unknown keep '{value}'"))),
            };
            let subset = subset.map(|names| names.into_iter().map(col).collect());
            let frame = registry::frame(b::handle(v, "frame")?)?.lazy();
            let output = if b::optional_bool(v, "maintainOrder", false)? {
                frame.unique_stable_generic(subset, keep)
            } else {
                frame.unique_generic(subset, keep)
            };
            frame_response(output.collect()?)?
        }
        "frameDropNulls" => {
            fields(v, &["frame", "subset"])?;
            let subset = optional_names(v, "subset")?;
            frame_response(registry::frame(b::handle(v, "frame")?)?.drop_nulls(subset.as_deref())?)?
        }
        "frameExplode" => {
            fields(v, &["frame", "columns", "emptyAsNull", "keepNulls"])?;
            if !b::optional_bool(v, "emptyAsNull", true)?
                || !b::optional_bool(v, "keepNulls", true)?
            {
                return Err(EngineError::Invalid(
                    "explode requires emptyAsNull=true and keepNulls=true".into(),
                ));
            }
            frame_response(
                registry::frame(b::handle(v, "frame")?)?
                    .lazy()
                    .explode(
                        by_name(b::names(v, "columns")?, true, false),
                        ExplodeOptions {
                            empty_as_null: true,
                            keep_nulls: true,
                        },
                    )
                    .collect()?,
            )?
        }
        "frameUnnest" => {
            fields(v, &["frame", "columns"])?;
            frame_response(
                registry::frame(b::handle(v, "frame")?)?
                    .lazy()
                    .unnest(by_name(b::names(v, "columns")?, true, false), None)
                    .collect()?,
            )?
        }
        "frameUnpivot" => {
            fields(v, &["frame", "on", "index", "variableName", "valueName"])?;
            frame_response(
                registry::frame(b::handle(v, "frame")?)?
                    .lazy()
                    .unpivot(UnpivotArgsDSL {
                        on: v
                            .get("on")
                            .map(|_| b::names(v, "on").map(|names| by_name(names, true, false)))
                            .transpose()?,
                        index: by_name(b::names(v, "index")?, true, false),
                        variable_name: v
                            .get("variableName")
                            .map(|_| b::string(v, "variableName").map(Into::into))
                            .transpose()?,
                        value_name: v
                            .get("valueName")
                            .map(|_| b::string(v, "valueName").map(Into::into))
                            .transpose()?,
                    })
                    .collect()?,
            )?
        }
        "frameTranspose" => {
            fields(v, &["frame", "includeHeader", "headerName", "columnNames"])?;
            let include_header = b::optional_bool(v, "includeHeader", false)?;
            let header_name = optional_string(v, "headerName", "column")?;
            let column_names = optional_names(v, "columnNames")?;
            let mut frame = registry::frame(b::handle(v, "frame")?)?;
            frame_response(frame.transpose(
                include_header.then_some(header_name),
                column_names.map(Either::Right),
            )?)?
        }
        "frameDrop" => {
            fields(v, &["frame", "columns", "strict"])?;
            let frame = registry::frame(b::handle(v, "frame")?)?;
            let selection = by_name(b::names(v, "columns")?, b::boolean(v, "strict")?, false);
            frame_response(frame.lazy().drop(selection).collect()?)?
        }
        "frameRename" => {
            fields(v, &["frame", "existing", "new", "strict"])?;
            let old = b::names(v, "existing")?;
            let new = b::names(v, "new")?;
            if old.len() != new.len() {
                return Err(EngineError::Invalid("rename lengths differ".into()));
            }
            frame_response(
                registry::frame(b::handle(v, "frame")?)?
                    .lazy()
                    .rename(old, new, b::boolean(v, "strict")?)
                    .collect()?,
            )?
        }
        _ => return Ok(None),
    };
    Ok(Some(output))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn invoke_frame(command: &str, frame: DataFrame, fields: Value) -> DataFrame {
        let handle = registry::insert(Entry::Frame(frame)).unwrap();
        let mut request = json!({
            "protocol": 2,
            "command": command,
            "frame": handle.to_string(),
        });
        request
            .as_object_mut()
            .unwrap()
            .extend(fields.as_object().unwrap().clone());
        let response = dispatch(command, &request).unwrap().unwrap();
        registry::frame(response["handle"].as_str().unwrap().parse().unwrap()).unwrap()
    }

    #[test]
    fn eager_single_frame_tranche_executes_through_protocol_dispatch() {
        let flat = df!(
            "key" => &[1i32, 1, 2],
            "value" => &[Some(10i32), None, Some(30)],
        )
        .unwrap();
        let distinct = invoke_frame(
            "frameDistinct",
            flat.clone(),
            json!({"subset":["key"],"keep":"last","maintainOrder":true}),
        );
        assert_eq!(distinct.height(), 2);
        let non_null = invoke_frame("frameDropNulls", flat.clone(), json!({"subset":["value"]}));
        assert_eq!(non_null.height(), 2);
        let unpivoted = invoke_frame(
            "frameUnpivot",
            flat.clone(),
            json!({"on":["value"],"index":["key"],"variableName":"metric","valueName":"reading"}),
        );
        assert_eq!(
            unpivoted
                .get_column_names()
                .iter()
                .map(|name| name.as_str())
                .collect::<Vec<_>>(),
            ["key", "metric", "reading"]
        );
        let transposed = invoke_frame(
            "frameTranspose",
            flat,
            json!({"includeHeader":true,"headerName":"source","columnNames":["r0","r1","r2"]}),
        );
        assert_eq!(transposed.shape(), (2, 4));

        let items = Series::new(
            "items".into(),
            &[
                Series::new("".into(), &[1i32, 2]),
                Series::new("".into(), &[3i32]),
            ],
        );
        let exploded = invoke_frame(
            "frameExplode",
            DataFrame::new(2, vec![items.into()]).unwrap(),
            json!({"columns":["items"],"emptyAsNull":true,"keepNulls":true}),
        );
        assert_eq!(exploded.height(), 3);

        let fields = [
            Series::new("left".into(), &[1i32, 2]),
            Series::new("right".into(), &[3i32, 4]),
        ];
        let record = StructChunked::from_series("record".into(), 2, fields.iter())
            .unwrap()
            .into_series();
        let unnested = invoke_frame(
            "frameUnnest",
            DataFrame::new(2, vec![record.into()]).unwrap(),
            json!({"columns":["record"]}),
        );
        assert_eq!(
            unnested
                .get_column_names()
                .iter()
                .map(|name| name.as_str())
                .collect::<Vec<_>>(),
            ["left", "right"]
        );
    }
}
