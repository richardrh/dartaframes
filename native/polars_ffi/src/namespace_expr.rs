//! Qualified expression namespaces and expression metadata.
//!
//! These mappings mirror the Polars 0.55.2 Rust DSL. Keep each wire shape
//! closed here rather than allowing namespace options through the generic
//! expression-function path.

use crate::{
    bindings,
    error::{EngineError, Result},
    registry,
};
use polars::lazy::dsl::lit;
use polars::prelude::*;
use serde_json::{json, Value};

const BASE_FIELDS: [&str; 5] = ["protocol", "command", "input", "name", "arguments"];

fn exact(name: &str, arguments: &[Expr], expected: usize) -> Result<()> {
    if arguments.len() == expected {
        Ok(())
    } else {
        Err(EngineError::Invalid(format!(
            "function '{name}' requires exactly {expected} argument(s)"
        )))
    }
}

fn fields(v: &Value, options: &[&str]) -> Result<()> {
    let mut allowed = BASE_FIELDS.to_vec();
    allowed.extend(options);
    bindings::validate_fields(v, &allowed)
}

fn i64_field(v: &Value, key: &str) -> Result<i64> {
    bindings::req(v, key)?
        .as_i64()
        .ok_or_else(|| EngineError::Invalid(format!("'{key}' must be an integer")))
}

fn usize_field(v: &Value, key: &str) -> Result<usize> {
    usize::try_from(
        bindings::req(v, key)?
            .as_u64()
            .ok_or_else(|| EngineError::Invalid(format!("'{key}' must be unsigned")))?,
    )
    .map_err(|_| EngineError::Invalid(format!("'{key}' is too large")))
}

fn time_unit(v: &Value, key: &str) -> Result<TimeUnit> {
    match bindings::string(v, key)? {
        "nanoseconds" => Ok(TimeUnit::Nanoseconds),
        "microseconds" => Ok(TimeUnit::Microseconds),
        "milliseconds" => Ok(TimeUnit::Milliseconds),
        value => Err(EngineError::Invalid(format!("unknown time unit '{value}'"))),
    }
}

fn sort_options(v: &Value) -> Result<SortOptions> {
    Ok(SortOptions {
        descending: bindings::boolean(v, "descending")?,
        nulls_last: bindings::boolean(v, "nullsLast")?,
        ..Default::default()
    })
}

fn strptime_options(v: &Value) -> Result<StrptimeOptions> {
    let format = v
        .get("format")
        .map(|x| {
            x.as_str()
                .filter(|x| !x.is_empty())
                .map(Into::into)
                .ok_or_else(|| EngineError::Invalid("'format' must be a non-empty string".into()))
        })
        .transpose()?;
    Ok(StrptimeOptions {
        format,
        strict: bindings::boolean(v, "strict")?,
        exact: bindings::boolean(v, "exact")?,
        cache: bindings::boolean(v, "cache")?,
    })
}

/// Dispatch a qualified function, returning `None` for unqualified functions.
pub fn function(v: &Value, name: &str, x: Expr, mut arguments: Vec<Expr>) -> Result<Option<Expr>> {
    let options: &[&str] = match name {
        "str.contains" | "str.find" => &["literal", "strict"],
        "str.extract" => &["groupIndex"],
        "str.split" => &["inclusive", "regex", "strict"],
        "str.replace" => &["literal", "replaceAll"],
        "str.padStart" | "str.padEnd" => &["fill"],
        "str.toDate" | "str.toTime" => &["format", "strict", "exact", "cache"],
        "str.toDatetime" => &["format", "strict", "exact", "cache", "timeUnit", "timeZone"],
        "str.lenBytes"
        | "str.lenChars"
        | "str.toLowercase"
        | "str.toUppercase"
        | "str.startsWith"
        | "str.endsWith"
        | "str.extractAll"
        | "str.stripChars"
        | "str.stripCharsStart"
        | "str.stripCharsEnd"
        | "str.stripPrefix"
        | "str.stripSuffix"
        | "str.slice"
        | "str.head"
        | "str.tail"
        | "str.zfill" => &[],
        name if name.starts_with("dt.") => match name {
            "dt.timestamp" => &["timeUnit"],
            "dt.format" => &["format"],
            "dt.convertTimeZone" => &["timeZone"],
            "dt.truncate" | "dt.round" | "dt.offsetBy" | "dt.year" | "dt.isoYear" | "dt.month"
            | "dt.day" | "dt.ordinalDay" | "dt.weekday" | "dt.week" | "dt.quarter" | "dt.hour"
            | "dt.minute" | "dt.second" | "dt.millisecond" | "dt.microsecond" | "dt.nanosecond"
            | "dt.date" | "dt.time" | "dt.baseUtcOffset" | "dt.dstOffset" => &[],
            _ => return Ok(None),
        },
        name if name.starts_with("list.") => match name {
            "list.get" | "list.contains" => &[if name == "list.get" {
                "nullOnOob"
            } else {
                "nullsEqual"
            }],
            "list.sort" => &["descending", "nullsLast"],
            "list.len" | "list.first" | "list.last" | "list.sum" | "list.min" | "list.max"
            | "list.mean" | "list.slice" => &[],
            _ => return Ok(None),
        },
        name if name.starts_with("arr.") => match name {
            "arr.get" | "arr.contains" => &[if name == "arr.get" {
                "nullOnOob"
            } else {
                "nullsEqual"
            }],
            "arr.sort" => &["descending", "nullsLast"],
            "arr.explode" => &["emptyAsNull", "keepNulls"],
            "arr.len" | "arr.sum" | "arr.min" | "arr.max" | "arr.mean" | "arr.toList" => &[],
            _ => return Ok(None),
        },
        name if name.starts_with("struct.") => match name {
            "struct.field" => &["field"],
            "struct.fieldAt" => &["index"],
            "struct.renameFields" => &["fields"],
            "struct.jsonEncode" => &[],
            _ => return Ok(None),
        },
        "bin.sizeBytes" | "bin.contains" | "bin.startsWith" | "bin.endsWith" | "bin.hexEncode"
        | "bin.base64Encode" | "cat.physical" | "cat.categories" => &[],
        name if name.starts_with("name.") => match name {
            "name.prefix" | "name.suffix" => &["value"],
            "name.keep" | "name.toLowercase" | "name.toUppercase" => &[],
            _ => return Ok(None),
        },
        "meta.undoAliases" => &[],
        _ => return Ok(None),
    };
    fields(v, options)?;

    let expression = match name {
        "str.lenBytes" => {
            exact(name, &arguments, 0)?;
            x.str().len_bytes()
        }
        "str.lenChars" => {
            exact(name, &arguments, 0)?;
            x.str().len_chars()
        }
        "str.toLowercase" => {
            exact(name, &arguments, 0)?;
            x.str().to_lowercase()
        }
        "str.toUppercase" => {
            exact(name, &arguments, 0)?;
            x.str().to_uppercase()
        }
        "str.startsWith" => {
            exact(name, &arguments, 1)?;
            x.str().starts_with(arguments.remove(0))
        }
        "str.endsWith" => {
            exact(name, &arguments, 1)?;
            x.str().ends_with(arguments.remove(0))
        }
        "str.contains" | "str.find" => {
            exact(name, &arguments, 1)?;
            let pattern = arguments.remove(0);
            let literal = bindings::boolean(v, "literal")?;
            let strict = bindings::boolean(v, "strict")?;
            match (name, literal) {
                ("str.contains", true) => x.str().contains_literal(pattern),
                ("str.contains", false) => x.str().contains(pattern, strict),
                ("str.find", true) => x.str().find_literal(pattern),
                ("str.find", false) => x.str().find(pattern, strict),
                _ => unreachable!(),
            }
        }
        "str.extract" => {
            exact(name, &arguments, 1)?;
            x.str()
                .extract(arguments.remove(0), usize_field(v, "groupIndex")?)
        }
        "str.extractAll" => {
            exact(name, &arguments, 1)?;
            x.str().extract_all(arguments.remove(0))
        }
        "str.split" => {
            exact(name, &arguments, 1)?;
            let by = arguments.remove(0);
            let inclusive = bindings::boolean(v, "inclusive")?;
            if bindings::boolean(v, "regex")? {
                if inclusive {
                    x.str()
                        .split_regex_inclusive(by, bindings::boolean(v, "strict")?)
                } else {
                    x.str().split_regex(by, bindings::boolean(v, "strict")?)
                }
            } else if inclusive {
                x.str().split_inclusive(by)
            } else {
                x.str().split(by)
            }
        }
        "str.replace" => {
            exact(name, &arguments, 2)?;
            let pattern = arguments.remove(0);
            let replacement = arguments.remove(0);
            if bindings::boolean(v, "replaceAll")? {
                x.str()
                    .replace_all(pattern, replacement, bindings::boolean(v, "literal")?)
            } else {
                x.str()
                    .replace(pattern, replacement, bindings::boolean(v, "literal")?)
            }
        }
        "str.stripChars" | "str.stripCharsStart" | "str.stripCharsEnd" => {
            if arguments.len() > 1 {
                return Err(EngineError::Invalid(format!(
                    "function '{name}' accepts at most one argument"
                )));
            }
            let chars = arguments.pop().unwrap_or_else(|| lit(NULL));
            match name {
                "str.stripChars" => x.str().strip_chars(chars),
                "str.stripCharsStart" => x.str().strip_chars_start(chars),
                _ => x.str().strip_chars_end(chars),
            }
        }
        "str.stripPrefix" => {
            exact(name, &arguments, 1)?;
            x.str().strip_prefix(arguments.remove(0))
        }
        "str.stripSuffix" => {
            exact(name, &arguments, 1)?;
            x.str().strip_suffix(arguments.remove(0))
        }
        "str.slice" => {
            exact(name, &arguments, 2)?;
            let offset = arguments.remove(0);
            x.str().slice(offset, arguments.remove(0))
        }
        "str.head" => {
            exact(name, &arguments, 1)?;
            x.str().head(arguments.remove(0))
        }
        "str.tail" => {
            exact(name, &arguments, 1)?;
            x.str().tail(arguments.remove(0))
        }
        "str.padStart" | "str.padEnd" => {
            exact(name, &arguments, 1)?;
            let fill = bindings::string(v, "fill")?;
            let mut chars = fill.chars();
            let fill = chars
                .next()
                .filter(|_| chars.next().is_none())
                .ok_or_else(|| EngineError::Invalid("'fill' must be one Unicode scalar".into()))?;
            if name == "str.padStart" {
                x.str().pad_start(arguments.remove(0), fill)
            } else {
                x.str().pad_end(arguments.remove(0), fill)
            }
        }
        "str.zfill" => {
            exact(name, &arguments, 1)?;
            x.str().zfill(arguments.remove(0))
        }
        "str.toDate" => {
            exact(name, &arguments, 0)?;
            x.str().to_date(strptime_options(v)?)
        }
        "str.toTime" => {
            exact(name, &arguments, 0)?;
            x.str().to_time(strptime_options(v)?)
        }
        "str.toDatetime" => {
            exact(name, &arguments, 1)?;
            let unit = v
                .get("timeUnit")
                .map(|_| time_unit(v, "timeUnit"))
                .transpose()?;
            let zone = if v.get("timeZone").is_some() {
                TimeZone::opt_try_new(Some(bindings::string(v, "timeZone")?))?
            } else {
                None
            };
            x.str()
                .to_datetime(unit, zone, strptime_options(v)?, arguments.remove(0))
        }
        name if name.starts_with("dt.") => datetime(v, name, x, arguments)?,
        name if name.starts_with("list.") => list(v, name, x, arguments)?,
        name if name.starts_with("arr.") => array(v, name, x, arguments)?,
        "struct.field" => {
            exact(name, &arguments, 0)?;
            x.struct_().field_by_name(bindings::string(v, "field")?)
        }
        "struct.fieldAt" => {
            exact(name, &arguments, 0)?;
            x.struct_().field_by_index(i64_field(v, "index")?)
        }
        "struct.renameFields" => {
            exact(name, &arguments, 0)?;
            x.struct_().rename_fields(bindings::names(v, "fields")?)
        }
        "struct.jsonEncode" => {
            exact(name, &arguments, 0)?;
            x.struct_().json_encode()
        }
        "bin.sizeBytes" => {
            exact(name, &arguments, 0)?;
            x.binary().size_bytes()
        }
        "bin.contains" => {
            exact(name, &arguments, 1)?;
            x.binary().contains_literal(arguments.remove(0))
        }
        "bin.startsWith" => {
            exact(name, &arguments, 1)?;
            x.binary().starts_with(arguments.remove(0))
        }
        "bin.endsWith" => {
            exact(name, &arguments, 1)?;
            x.binary().ends_with(arguments.remove(0))
        }
        "bin.hexEncode" => {
            exact(name, &arguments, 0)?;
            x.binary().hex_encode()
        }
        "bin.base64Encode" => {
            exact(name, &arguments, 0)?;
            x.binary().base64_encode()
        }
        "cat.physical" => {
            exact(name, &arguments, 0)?;
            x.cat().physical()
        }
        "cat.categories" => {
            exact(name, &arguments, 0)?;
            x.cat().get_categories()
        }
        "name.keep" => {
            exact(name, &arguments, 0)?;
            x.name().keep()
        }
        "name.prefix" => {
            exact(name, &arguments, 0)?;
            x.name().prefix(
                bindings::req(v, "value")?
                    .as_str()
                    .ok_or_else(|| EngineError::Invalid("'value' must be a string".into()))?,
            )
        }
        "name.suffix" => {
            exact(name, &arguments, 0)?;
            x.name().suffix(
                bindings::req(v, "value")?
                    .as_str()
                    .ok_or_else(|| EngineError::Invalid("'value' must be a string".into()))?,
            )
        }
        "name.toLowercase" => {
            exact(name, &arguments, 0)?;
            x.name().to_lowercase()
        }
        "name.toUppercase" => {
            exact(name, &arguments, 0)?;
            x.name().to_uppercase()
        }
        "meta.undoAliases" => {
            exact(name, &arguments, 0)?;
            x.meta().undo_aliases()
        }
        _ => unreachable!(),
    };
    Ok(Some(expression))
}

fn datetime(v: &Value, name: &str, x: Expr, mut arguments: Vec<Expr>) -> Result<Expr> {
    let unary = arguments.is_empty();
    let expression = match name {
        "dt.year" => x.dt().year(),
        "dt.isoYear" => x.dt().iso_year(),
        "dt.month" => x.dt().month(),
        "dt.day" => x.dt().day(),
        "dt.ordinalDay" => x.dt().ordinal_day(),
        "dt.weekday" => x.dt().weekday(),
        "dt.week" => x.dt().week(),
        "dt.quarter" => x.dt().quarter(),
        "dt.hour" => x.dt().hour(),
        "dt.minute" => x.dt().minute(),
        "dt.second" => x.dt().second(),
        "dt.millisecond" => x.dt().millisecond(),
        "dt.microsecond" => x.dt().microsecond(),
        "dt.nanosecond" => x.dt().nanosecond(),
        "dt.date" => x.dt().date(),
        "dt.time" => x.dt().time(),
        "dt.timestamp" => x.dt().timestamp(time_unit(v, "timeUnit")?),
        "dt.format" => x.dt().to_string(bindings::string(v, "format")?),
        "dt.convertTimeZone" => x.dt().convert_time_zone(
            TimeZone::opt_try_new(Some(bindings::string(v, "timeZone")?))?.unwrap(),
        ),
        "dt.baseUtcOffset" => x.dt().base_utc_offset(),
        "dt.dstOffset" => x.dt().dst_offset(),
        "dt.truncate" | "dt.round" | "dt.offsetBy" => {
            exact(name, &arguments, 1)?;
            let argument = arguments.remove(0);
            return Ok(match name {
                "dt.truncate" => x.dt().truncate(argument),
                "dt.round" => x.dt().round(argument),
                _ => x.dt().offset_by(argument),
            });
        }
        _ => unreachable!(),
    };
    if !unary {
        exact(name, &arguments, 0)?;
    }
    Ok(expression)
}

fn list(v: &Value, name: &str, x: Expr, mut arguments: Vec<Expr>) -> Result<Expr> {
    Ok(match name {
        "list.len" => {
            exact(name, &arguments, 0)?;
            x.list().len()
        }
        "list.first" => {
            exact(name, &arguments, 0)?;
            x.list().first()
        }
        "list.last" => {
            exact(name, &arguments, 0)?;
            x.list().last()
        }
        "list.sum" => {
            exact(name, &arguments, 0)?;
            x.list().sum()
        }
        "list.min" => {
            exact(name, &arguments, 0)?;
            x.list().min()
        }
        "list.max" => {
            exact(name, &arguments, 0)?;
            x.list().max()
        }
        "list.mean" => {
            exact(name, &arguments, 0)?;
            x.list().mean()
        }
        "list.get" => {
            exact(name, &arguments, 1)?;
            x.list()
                .get(arguments.remove(0), bindings::boolean(v, "nullOnOob")?)
        }
        "list.contains" => {
            exact(name, &arguments, 1)?;
            x.list()
                .contains(arguments.remove(0), bindings::boolean(v, "nullsEqual")?)
        }
        "list.sort" => {
            exact(name, &arguments, 0)?;
            x.list().sort(sort_options(v)?)
        }
        "list.slice" => {
            exact(name, &arguments, 2)?;
            let offset = arguments.remove(0);
            x.list().slice(offset, arguments.remove(0))
        }
        _ => unreachable!(),
    })
}

fn array(v: &Value, name: &str, x: Expr, mut arguments: Vec<Expr>) -> Result<Expr> {
    Ok(match name {
        "arr.len" => {
            exact(name, &arguments, 0)?;
            x.arr().len()
        }
        "arr.sum" => {
            exact(name, &arguments, 0)?;
            x.arr().sum()
        }
        "arr.min" => {
            exact(name, &arguments, 0)?;
            x.arr().min()
        }
        "arr.max" => {
            exact(name, &arguments, 0)?;
            x.arr().max()
        }
        "arr.mean" => {
            exact(name, &arguments, 0)?;
            x.arr().mean()
        }
        "arr.toList" => {
            exact(name, &arguments, 0)?;
            x.arr().to_list()
        }
        "arr.get" => {
            exact(name, &arguments, 1)?;
            x.arr()
                .get(arguments.remove(0), bindings::boolean(v, "nullOnOob")?)
        }
        "arr.contains" => {
            exact(name, &arguments, 1)?;
            x.arr()
                .contains(arguments.remove(0), bindings::boolean(v, "nullsEqual")?)
        }
        "arr.sort" => {
            exact(name, &arguments, 0)?;
            x.arr().sort(sort_options(v)?)
        }
        "arr.explode" => {
            exact(name, &arguments, 0)?;
            x.arr().explode(ExplodeOptions {
                empty_as_null: bindings::boolean(v, "emptyAsNull")?,
                keep_nulls: bindings::boolean(v, "keepNulls")?,
            })
        }
        _ => unreachable!(),
    })
}

pub fn metadata(v: &Value) -> Result<Value> {
    let op = bindings::string(v, "op")?;
    let options: &[&str] = match op {
        "isColumnSelection" | "isLiteral" => &["allowAliasing"],
        "rootNames" | "outputName" | "isColumn" | "hasMultipleOutputs" | "isRegexProjection" => &[],
        value => {
            return Err(EngineError::Unsupported(format!(
                "expression metadata '{value}'"
            )))
        }
    };
    let mut allowed = vec!["protocol", "command", "input", "op"];
    allowed.extend(options);
    bindings::validate_fields(v, &allowed)?;
    let expression = registry::expr(bindings::handle(v, "input")?)?;
    let meta = expression.meta();
    Ok(match op {
        "rootNames" => {
            json!({"value": meta.root_names().iter().map(|x| x.as_str()).collect::<Vec<_>>() })
        }
        "outputName" => json!({"value": meta.output_name()?.as_str()}),
        "isColumn" => json!({"value": meta.is_column()}),
        "isColumnSelection" => {
            json!({"value": meta.is_column_selection(bindings::boolean(v, "allowAliasing")?)})
        }
        "isLiteral" => json!({"value": meta.is_literal(bindings::boolean(v, "allowAliasing")?)}),
        "hasMultipleOutputs" => json!({"value": meta.has_multiple_outputs()}),
        "isRegexProjection" => json!({"value": meta.is_regex_projection()}),
        _ => unreachable!(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn qualified_schemas_are_closed() {
        let valid = json!({
            "protocol": 2, "command": "exprFunction", "input": "1",
            "name": "str.split", "arguments": [], "inclusive": false,
            "regex": false, "strict": true
        });
        assert!(function(&valid, "str.split", lit("a,b"), vec![lit(",")])
            .unwrap()
            .is_some());

        let mut invalid = valid;
        invalid["nullsLast"] = json!(false);
        assert!(function(&invalid, "str.split", lit("a,b"), vec![lit(",")]).is_err());
    }

    #[test]
    fn unknown_qualified_name_is_not_claimed() {
        let request = json!({
            "protocol": 2, "command": "exprFunction", "input": "1",
            "name": "str.notReal", "arguments": []
        });
        assert!(function(&request, "str.notReal", lit("a"), vec![])
            .unwrap()
            .is_none());
    }
}
