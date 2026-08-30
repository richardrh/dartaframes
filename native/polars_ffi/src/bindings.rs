use crate::{
    advanced_expr, batch, dtype,
    error::{EngineError, Result},
    namespace_expr, registry,
};
use polars::lazy::dsl::{
    by_name, coalesce, concat, concat_lf_diagonal, concat_lf_horizontal, lit, HConcatOptions,
    UnionArgs, UnpivotArgsDSL,
};
use polars::prelude::*;
use serde_json::Value;

const MAX_ITEMS: usize = 10_000;

pub fn validate_fields(v: &Value, allowed: &[&str]) -> Result<()> {
    let object = v
        .as_object()
        .ok_or_else(|| EngineError::Invalid("request must be an object".into()))?;
    for key in object.keys() {
        if !allowed.contains(&key.as_str()) {
            return Err(EngineError::Invalid(format!(
                "unknown or irrelevant field '{key}'"
            )));
        }
    }
    Ok(())
}
pub fn req<'a>(v: &'a Value, key: &str) -> Result<&'a Value> {
    v.get(key)
        .ok_or_else(|| EngineError::Invalid(format!("missing '{key}'")))
}
pub fn string<'a>(v: &'a Value, key: &str) -> Result<&'a str> {
    let value = req(v, key)?
        .as_str()
        .ok_or_else(|| EngineError::Invalid(format!("'{key}' must be a string")))?;
    if value.is_empty() {
        return Err(EngineError::Invalid(format!("'{key}' must not be empty")));
    }
    Ok(value)
}
pub fn boolean(v: &Value, key: &str) -> Result<bool> {
    req(v, key)?
        .as_bool()
        .ok_or_else(|| EngineError::Invalid(format!("'{key}' must be a boolean")))
}
pub fn optional_bool(v: &Value, key: &str, default: bool) -> Result<bool> {
    v.get(key)
        .map(|x| {
            x.as_bool()
                .ok_or_else(|| EngineError::Invalid(format!("'{key}' must be a boolean")))
        })
        .unwrap_or(Ok(default))
}
fn optional_string<'a>(v: &'a Value, key: &str, default: &'a str) -> Result<&'a str> {
    v.get(key)
        .map(|x| {
            x.as_str()
                .ok_or_else(|| EngineError::Invalid(format!("'{key}' must be a string")))
        })
        .unwrap_or(Ok(default))
}
pub fn handle(v: &Value, key: &str) -> Result<u64> {
    let text = req(v, key)?.as_str().ok_or_else(|| {
        EngineError::Invalid(format!("'{key}' must be an unsigned decimal string"))
    })?;
    if text.is_empty() || !text.bytes().all(|b| b.is_ascii_digit()) {
        return Err(EngineError::Invalid(format!("invalid '{key}' handle")));
    }
    text.parse()
        .map_err(|_| EngineError::Invalid(format!("invalid '{key}' handle")))
}
pub fn handles(v: &Value, key: &str) -> Result<Vec<u64>> {
    let values = req(v, key)?
        .as_array()
        .ok_or_else(|| EngineError::Invalid(format!("'{key}' must be an array")))?;
    if values.len() > MAX_ITEMS {
        return Err(EngineError::Invalid(format!("too many values in '{key}'")));
    }
    values
        .iter()
        .map(|x| handle(&serde_json::json!({key:x}), key))
        .collect()
}
pub fn exprs(v: &Value, key: &str) -> Result<Vec<Expr>> {
    handles(v, key)?.into_iter().map(registry::expr).collect()
}
pub fn expr_inputs(v: &Value, key: &str) -> Result<Vec<Expr>> {
    handles(v, key)?
        .into_iter()
        .map(registry::expr_input)
        .collect()
}
pub fn names(v: &Value, key: &str) -> Result<Vec<PlSmallStr>> {
    let values = req(v, key)?
        .as_array()
        .ok_or_else(|| EngineError::Invalid(format!("'{key}' must be an array")))?;
    if values.len() > MAX_ITEMS {
        return Err(EngineError::Invalid(format!("too many values in '{key}'")));
    }
    values
        .iter()
        .map(|x| {
            x.as_str()
                .filter(|x| !x.is_empty())
                .map(Into::into)
                .ok_or_else(|| {
                    EngineError::Invalid(format!("'{key}' values must be non-empty strings"))
                })
        })
        .collect()
}
fn optional_names(v: &Value, key: &str) -> Result<Option<Vec<PlSmallStr>>> {
    v.get(key).map(|_| names(v, key)).transpose()
}
fn bools(v: &Value, key: &str, len: usize, default: bool) -> Result<Vec<bool>> {
    let Some(raw) = v.get(key) else {
        return Ok(vec![default; len]);
    };
    let values = raw
        .as_array()
        .ok_or_else(|| EngineError::Invalid(format!("'{key}' must be an array")))?;
    if values.len() != len {
        return Err(EngineError::Invalid(format!(
            "'{key}' length must match expressions"
        )));
    }
    values
        .iter()
        .map(|x| {
            x.as_bool()
                .ok_or_else(|| EngineError::Invalid(format!("'{key}' values must be booleans")))
        })
        .collect()
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
pub fn literal(scalar: &Value) -> Result<Expr> {
    validate_fields(
        scalar,
        &["dtype", "value", "floatBits", "base64", "unscaled"],
    )?;
    let dt = req(scalar, "dtype")?;
    let payloads = ["value", "floatBits", "base64", "unscaled"]
        .into_iter()
        .filter(|k| scalar.get(k).is_some())
        .collect::<Vec<_>>();
    if payloads.len() != 1 {
        return Err(EngineError::Invalid(
            "scalar requires exactly one value payload".into(),
        ));
    }
    let val = match payloads[0] {
        "value" => scalar["value"].clone(),
        "floatBits" => serde_json::json!({"floatBits":scalar["floatBits"]}),
        "base64" => serde_json::json!({"base64":scalar["base64"]}),
        _ => serde_json::json!({"value":scalar["unscaled"]}),
    };
    let df = batch::import(
        &serde_json::json!({"columns":[{"name":"literal","dtype":dt,"values":[val]}]}),
    )?;
    let series = df.column("literal")?.as_materialized_series();
    Ok(Expr::Literal(
        Scalar::new(series.dtype().clone(), series.get(0)?.into_static()).into(),
    ))
}

pub fn unary(v: &Value) -> Result<Expr> {
    let x = registry::expr(handle(v, "input")?)?;
    Ok(match string(v, "op")? {
        "not" => x.not(),
        "negate" | "neg" => -x,
        "isNull" => x.is_null(),
        "isNotNull" => x.is_not_null(),
        "isNan" => x.is_nan(),
        "isNotNan" => x.is_not_nan(),
        op => return Err(EngineError::Unsupported(format!("unary operation '{op}'"))),
    })
}
pub fn binary(v: &Value) -> Result<Expr> {
    let l = registry::expr(handle(v, "left")?)?;
    let r = registry::expr(handle(v, "right")?)?;
    Ok(match string(v, "op")? {
        "eq" => l.eq(r),
        "eqValidity" => l.eq_missing(r),
        "notEq" => l.neq(r),
        "notEqValidity" => l.neq_missing(r),
        "lt" => l.lt(r),
        "ltEq" => l.lt_eq(r),
        "gt" => l.gt(r),
        "gtEq" => l.gt_eq(r),
        "add" => l + r,
        "subtract" => l - r,
        "multiply" => l * r,
        "trueDivide" => l.true_div(r),
        "floorDivide" => l.floor_div(r),
        "modulo" => l % r,
        "bitAnd" => l.and(r),
        "logicalAnd" => l.logical_and(r),
        "bitOr" => l.or(r),
        "logicalOr" => l.logical_or(r),
        "bitXor" => l.xor(r),
        op => return Err(EngineError::Unsupported(format!("binary operation '{op}'"))),
    })
}
pub fn aggregate(v: &Value) -> Result<Expr> {
    let op = string(v, "op")?;
    if op == "len" {
        return Err(EngineError::Invalid("use exprLen for len".into()));
    }
    let x = registry::expr(handle(v, "input")?)?;
    if let Some(expression) = advanced_expr::aggregate(v, op, x.clone())? {
        return Ok(expression);
    }
    Ok(match op {
        "count" => x.count(),
        "nullCount" => x.null_count(),
        "sum" => x.sum(),
        "mean" => x.mean(),
        "min" => x.min(),
        "max" => x.max(),
        "first" => x.first(),
        "last" => x.last(),
        "median" => x.median(),
        "nUnique" => x.n_unique(),
        "product" => x.product(),
        "std" => x.std(ddof(v)?),
        "variance" => x.var(ddof(v)?),
        "quantile" => {
            let q = req(v, "quantile")?
                .as_f64()
                .filter(|q| (0.0..=1.0).contains(q))
                .ok_or_else(|| EngineError::Invalid("quantile must be between 0 and 1".into()))?;
            let m = match optional_string(v, "interpolation", "nearest")? {
                "nearest" => QuantileMethod::Nearest,
                "lower" => QuantileMethod::Lower,
                "higher" => QuantileMethod::Higher,
                "midpoint" => QuantileMethod::Midpoint,
                "linear" => QuantileMethod::Linear,
                x => return Err(EngineError::Invalid(format!("unknown interpolation '{x}'"))),
            };
            x.quantile(lit(q), m)
        }
        op => return Err(EngineError::Unsupported(format!("aggregate '{op}'"))),
    })
}
fn ddof(v: &Value) -> Result<u8> {
    let value = v
        .get("ddof")
        .map(|x| {
            x.as_u64()
                .ok_or_else(|| EngineError::Invalid("'ddof' must be unsigned".into()))
        })
        .unwrap_or(Ok(1))?;
    u8::try_from(value).map_err(|_| EngineError::Invalid("ddof exceeds 255".into()))
}

pub fn function(v: &Value) -> Result<Expr> {
    let x = registry::expr(handle(v, "input")?)?;
    let name = string(v, "name")?;
    let mut a = exprs(v, "arguments")?;
    if let Some(expression) = namespace_expr::function(v, name, x.clone(), a.clone())? {
        return Ok(expression);
    }
    if let Some(expression) = advanced_expr::function(v, name, x.clone(), a.clone())? {
        return Ok(expression);
    }
    let options: &[&str] = match name {
        "round" => &["decimals", "mode"],
        "isIn" => &["nullsEqual"],
        "stringContains" => &["literal", "strict"],
        "stringReplace" => &["literal", "replaceAll"],
        "cumSum" | "cumMin" | "cumMax" => &["reverse"],
        "isNull" | "isNotNull" | "isNan" | "isNotNan" | "fillNull" | "abs" | "floor" | "ceil"
        | "clip" | "clipMin" | "clipMax" | "fillNan" | "isFinite" | "isInfinite" | "coalesce"
        | "lowercase" | "uppercase" | "stringStartsWith" | "stringEndsWith" | "stripChars"
        | "shift" => &[],
        other => return Err(EngineError::Unsupported(format!("function '{other}'"))),
    };
    let mut allowed = vec!["protocol", "command", "input", "name", "arguments"];
    allowed.extend(options);
    validate_fields(v, &allowed)?;
    let exact = |a: &Vec<Expr>, n| {
        if a.len() == n {
            Ok(())
        } else {
            Err(EngineError::Invalid(format!(
                "function '{name}' requires exactly {n} argument(s)"
            )))
        }
    };
    Ok(match name {
        "isNull" => {
            exact(&a, 0)?;
            x.is_null()
        }
        "isNotNull" => {
            exact(&a, 0)?;
            x.is_not_null()
        }
        "isNan" => {
            exact(&a, 0)?;
            x.is_nan()
        }
        "isNotNan" => {
            exact(&a, 0)?;
            x.is_not_nan()
        }
        "fillNull" => {
            exact(&a, 1)?;
            x.fill_null(a.remove(0))
        }
        "abs" => {
            exact(&a, 0)?;
            x.abs()
        }
        "floor" => {
            exact(&a, 0)?;
            x.floor()
        }
        "ceil" => {
            exact(&a, 0)?;
            x.ceil()
        }
        "round" => {
            exact(&a, 0)?;
            let d = u32::try_from(
                req(v, "decimals")?
                    .as_u64()
                    .ok_or_else(|| EngineError::Invalid("'decimals' must be unsigned".into()))?,
            )
            .map_err(|_| EngineError::Invalid("decimals exceeds uint32".into()))?;
            let m = match string(v, "mode")? {
                "halfToEven" => RoundMode::HalfToEven,
                "halfAwayFromZero" => RoundMode::HalfAwayFromZero,
                "toZero" => RoundMode::ToZero,
                m => return Err(EngineError::Invalid(format!("unknown round mode '{m}'"))),
            };
            x.round(d, m)
        }
        "clip" => {
            exact(&a, 2)?;
            let lo = a.remove(0);
            x.clip(lo, a.remove(0))
        }
        "clipMin" => {
            exact(&a, 1)?;
            x.clip_min(a.remove(0))
        }
        "clipMax" => {
            exact(&a, 1)?;
            x.clip_max(a.remove(0))
        }
        "fillNan" => {
            exact(&a, 1)?;
            x.fill_nan(a.remove(0))
        }
        "isFinite" => {
            exact(&a, 0)?;
            x.is_finite()
        }
        "isInfinite" => {
            exact(&a, 0)?;
            x.is_infinite()
        }
        "coalesce" => {
            if a.is_empty() {
                return Err(EngineError::Invalid("coalesce requires arguments".into()));
            }
            let mut all = vec![x];
            all.append(&mut a);
            coalesce(&all)
        }
        "isIn" => {
            exact(&a, 1)?;
            x.is_in(a.remove(0).implode(false), boolean(v, "nullsEqual")?)
        }
        "lowercase" => {
            exact(&a, 0)?;
            x.str().to_lowercase()
        }
        "uppercase" => {
            exact(&a, 0)?;
            x.str().to_uppercase()
        }
        "stringStartsWith" => {
            exact(&a, 1)?;
            x.str().starts_with(a.remove(0))
        }
        "stringEndsWith" => {
            exact(&a, 1)?;
            x.str().ends_with(a.remove(0))
        }
        "stringContains" => {
            exact(&a, 1)?;
            let literal = boolean(v, "literal")?;
            let strict = boolean(v, "strict")?;
            if literal {
                if strict {
                    return Err(EngineError::Invalid(
                        "strict is invalid for literal stringContains".into(),
                    ));
                }
                x.str().contains_literal(a.remove(0))
            } else {
                x.str().contains(a.remove(0), strict)
            }
        }
        "stringReplace" => {
            exact(&a, 2)?;
            let p = a.remove(0);
            let r = a.remove(0);
            if boolean(v, "replaceAll")? {
                x.str().replace_all(p, r, boolean(v, "literal")?)
            } else {
                x.str().replace(p, r, boolean(v, "literal")?)
            }
        }
        "stripChars" => {
            if a.len() > 1 {
                return Err(EngineError::Invalid(
                    "stripChars accepts at most one argument".into(),
                ));
            }
            x.str().strip_chars(a.pop().unwrap_or_else(|| lit(NULL)))
        }
        "shift" => {
            exact(&a, 1)?;
            x.shift(a.remove(0))
        }
        "cumSum" => {
            exact(&a, 0)?;
            x.cum_sum(boolean(v, "reverse")?)
        }
        "cumMin" => {
            exact(&a, 0)?;
            x.cum_min(boolean(v, "reverse")?)
        }
        "cumMax" => {
            exact(&a, 0)?;
            x.cum_max(boolean(v, "reverse")?)
        }
        _ => unreachable!(),
    })
}

pub fn scan_csv(v: &Value) -> Result<LazyFrame> {
    let mut r = LazyCsvReader::new(string(v, "path")?.into());
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
    r = r
        .with_has_header(optional_bool(v, "hasHeader", true)?)
        .with_separator(sep.as_bytes()[0])
        .with_skip_rows(usize_opt(v, "skipRows")?.unwrap_or(0))
        .with_n_rows(usize_opt(v, "nRows")?)
        .with_try_parse_dates(optional_bool(v, "tryParseDates", false)?);
    Ok(r.finish()?)
}
pub fn scan_parquet(v: &Value) -> Result<LazyFrame> {
    let args = ScanArgsParquet {
        n_rows: usize_opt(v, "nRows")?,
        parallel: if optional_bool(v, "parallel", true)? {
            ParallelStrategy::Auto
        } else {
            ParallelStrategy::None
        },
        ..Default::default()
    };
    Ok(LazyFrame::scan_parquet(string(v, "path")?.into(), args)?)
}
pub fn join_type(s: &str) -> Result<JoinType> {
    Ok(match s {
        "inner" => JoinType::Inner,
        "left" => JoinType::Left,
        "right" => JoinType::Right,
        "full" | "outer" => JoinType::Full,
        "semi" => JoinType::Semi,
        "anti" => JoinType::Anti,
        "cross" => JoinType::Cross,
        x => return Err(EngineError::Invalid(format!("unknown join type '{x}'"))),
    })
}
fn join_validation(v: &Value) -> Result<JoinValidation> {
    Ok(match optional_string(v, "validation", "manyToMany")? {
        "manyToMany" => JoinValidation::ManyToMany,
        "manyToOne" => JoinValidation::ManyToOne,
        "oneToMany" => JoinValidation::OneToMany,
        "oneToOne" => JoinValidation::OneToOne,
        x => {
            return Err(EngineError::Invalid(format!(
                "unknown join validation '{x}'"
            )))
        }
    })
}
fn join_order(v: &Value) -> Result<MaintainOrderJoin> {
    Ok(match optional_string(v, "maintainOrder", "none")? {
        "none" => MaintainOrderJoin::None,
        "left" => MaintainOrderJoin::Left,
        "right" => MaintainOrderJoin::Right,
        "leftRight" => MaintainOrderJoin::LeftRight,
        "rightLeft" => MaintainOrderJoin::RightLeft,
        x => return Err(EngineError::Invalid(format!("unknown join order '{x}'"))),
    })
}
pub fn lazy(v: &Value, command: &str) -> Result<LazyFrame> {
    let input = || registry::lazy_frame(handle(v, "input")?);
    Ok(match command {
        "lazySelect" => input()?.select(exprs(v, "expressions")?),
        "lazyFilter" => input()?.filter(registry::expr(handle(v, "predicate")?)?),
        "lazyWithColumns" => input()?.with_columns(exprs(v, "expressions")?),
        "lazySort" => {
            let by = exprs(v, "by")?;
            if by.is_empty() {
                return Err(EngineError::Invalid("sort.by must not be empty".into()));
            }
            let n = by.len();
            input()?.sort_by_exprs(
                by,
                SortMultipleOptions::default()
                    .with_order_descending_multi(bools(v, "descending", n, false)?)
                    .with_nulls_last_multi(bools(v, "nullsLast", n, false)?)
                    .with_maintain_order(optional_bool(v, "maintainOrder", false)?),
            )
        }
        "lazySlice" => input()?.slice(
            req(v, "offset")?
                .as_i64()
                .ok_or_else(|| EngineError::Invalid("offset must be an integer".into()))?,
            u32::try_from(
                req(v, "length")?
                    .as_u64()
                    .ok_or_else(|| EngineError::Invalid("length must be unsigned".into()))?,
            )
            .map_err(|_| EngineError::Invalid("length exceeds uint32".into()))?,
        ),
        "lazyGroupBy" => {
            let lf = input()?;
            let keys = exprs(v, "keys")?;
            let aggs = exprs(v, "aggregations")?;
            if optional_bool(v, "maintainOrder", false)? {
                lf.group_by_stable(keys).agg(aggs)
            } else {
                lf.group_by(keys).agg(aggs)
            }
        }
        "lazyJoin" => {
            let left = registry::lazy_frame(handle(v, "left")?)?;
            let right = registry::lazy_frame(handle(v, "right")?)?;
            let jt = join_type(string(v, "how")?)?;
            let le = exprs(v, "leftOn")?;
            let re = exprs(v, "rightOn")?;
            if jt == JoinType::Cross && (!le.is_empty() || !re.is_empty()) {
                return Err(EngineError::Invalid(
                    "cross join does not accept leftOn or rightOn keys".into(),
                ));
            }
            if le.len() != re.len() || (jt != JoinType::Cross && le.is_empty()) {
                return Err(EngineError::Invalid("invalid join keys".into()));
            }
            let coalesce = match v.get("coalesce") {
                None => JoinCoalesce::KeepColumns,
                Some(Value::Null) => JoinCoalesce::JoinSpecific,
                Some(value) => match value.as_bool() {
                    Some(true) => JoinCoalesce::CoalesceColumns,
                    Some(false) => JoinCoalesce::KeepColumns,
                    None => return Err(EngineError::Invalid("coalesce must be a boolean".into())),
                },
            };
            if coalesce == JoinCoalesce::CoalesceColumns
                && matches!(jt, JoinType::Semi | JoinType::Anti | JoinType::Cross)
            {
                return Err(EngineError::Invalid(
                    "coalesce is invalid for this join".into(),
                ));
            }
            let validation = join_validation(v)?;
            validation.is_valid_join(&jt)?;
            let allow_parallel = optional_bool(v, "allowParallel", true)?;
            let force_parallel = optional_bool(v, "forceParallel", false)?;
            if force_parallel && !allow_parallel {
                return Err(EngineError::Invalid(
                    "forceParallel requires allowParallel".into(),
                ));
            }
            left.join_builder()
                .with(right)
                .left_on(le)
                .right_on(re)
                .how(jt)
                .suffix(optional_string(v, "suffix", "_right")?)
                .coalesce(coalesce)
                .join_nulls(optional_bool(v, "nullsEqual", false)?)
                .validate(validation)
                .maintain_order(join_order(v)?)
                .allow_parallel(allow_parallel)
                .force_parallel(force_parallel)
                .finish()
        }
        "lazyDistinct" => {
            let subset = optional_names(v, "subset")?.map(|n| n.into_iter().map(col).collect());
            let keep = match optional_string(v, "keep", "first")? {
                "first" => UniqueKeepStrategy::First,
                "last" => UniqueKeepStrategy::Last,
                "any" => UniqueKeepStrategy::Any,
                "none" => UniqueKeepStrategy::None,
                x => return Err(EngineError::Invalid(format!("unknown keep '{x}'"))),
            };
            if optional_bool(v, "maintainOrder", false)? {
                input()?.unique_stable_generic(subset, keep)
            } else {
                input()?.unique_generic(subset, keep)
            }
        }
        "lazyDropNulls" => {
            input()?.drop_nulls(optional_names(v, "subset")?.map(|n| by_name(n, true, false)))
        }
        "lazyDrop" => input()?.drop(by_name(names(v, "columns")?, boolean(v, "strict")?, false)),
        "lazyRename" => {
            let old = names(v, "existing")?;
            let new = names(v, "new")?;
            if old.len() != new.len() {
                return Err(EngineError::Invalid("rename lengths differ".into()));
            }
            input()?.rename(old, new, boolean(v, "strict")?)
        }
        "lazyExplode" => {
            if !optional_bool(v, "emptyAsNull", true)? || !optional_bool(v, "keepNulls", true)? {
                return Err(EngineError::Invalid(
                    "explode requires emptyAsNull=true and keepNulls=true".into(),
                ));
            }
            input()?.explode(
                by_name(names(v, "columns")?, true, false),
                ExplodeOptions {
                    empty_as_null: true,
                    keep_nulls: true,
                },
            )
        }
        "lazyUnnest" => input()?.unnest(by_name(names(v, "columns")?, true, false), None),
        "lazyUnpivot" => input()?.unpivot(UnpivotArgsDSL {
            on: v
                .get("on")
                .map(|_| names(v, "on").map(|names| by_name(names, true, false)))
                .transpose()?,
            index: by_name(names(v, "index")?, true, false),
            variable_name: v
                .get("variableName")
                .map(|_| string(v, "variableName").map(Into::into))
                .transpose()?,
            value_name: v
                .get("valueName")
                .map(|_| string(v, "valueName").map(Into::into))
                .transpose()?,
        }),
        "lazyConcat" => {
            let hs = handles(v, "inputs")?;
            if hs.is_empty() {
                return Err(EngineError::Invalid(
                    "concat inputs must not be empty".into(),
                ));
            }
            let how = optional_string(v, "how", "vertical")?;
            let relaxed = match how {
                "vertical" | "diagonal" | "horizontal" => false,
                "verticalRelaxed" | "diagonalRelaxed" => true,
                x => return Err(EngineError::Invalid(format!("unknown concat mode '{x}'"))),
            };
            let frames = hs
                .into_iter()
                .map(registry::lazy_frame)
                .collect::<Result<Vec<_>>>()?;
            let args = UnionArgs {
                rechunk: optional_bool(v, "rechunk", false)?,
                to_supertypes: relaxed,
                strict: !relaxed,
                ..Default::default()
            };
            match how {
                "vertical" | "verticalRelaxed" => concat(frames, args)?,
                "diagonal" | "diagonalRelaxed" => concat_lf_diagonal(frames, args)?,
                "horizontal" => {
                    if args.rechunk {
                        return Err(EngineError::Invalid(
                            "horizontal concat does not support rechunk".into(),
                        ));
                    }
                    concat_lf_horizontal(frames, HConcatOptions::default())?
                }
                _ => unreachable!(),
            }
        }
        _ => {
            return Err(EngineError::Invalid(format!(
                "unknown lazy command '{command}'"
            )))
        }
    })
}

pub fn schema(lf: &LazyFrame) -> Result<Value> {
    let mut clone = lf.clone();
    let schema = clone.collect_schema()?;
    Ok(Value::Array(schema.iter().map(|(name,dt)|serde_json::json!({"name":name.as_str(),"dtype":dtype::descriptor(dt)})).collect()))
}
