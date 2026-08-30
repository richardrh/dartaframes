use crate::{
    bindings as b, dtype,
    error::{EngineError, Result},
    registry::{self, Entry},
};
use polars::prelude::*;
use serde_json::{json, Value};
use std::sync::Arc;

fn response(handle: u64, kind: &str) -> Value {
    json!({"handle": handle.to_string(), "kind": kind})
}

fn insert_selector(value: Selector) -> Result<Value> {
    Ok(response(
        registry::insert(Entry::Selector(value))?,
        "selector",
    ))
}

fn insert_dtype_selector(value: DataTypeSelector) -> Result<Value> {
    Ok(response(
        registry::insert(Entry::DataTypeSelector(value))?,
        "dtypeSelector",
    ))
}

fn fields(v: &Value, extra: &[&str]) -> Result<()> {
    let mut allowed = vec!["protocol", "command"];
    allowed.extend(extra);
    b::validate_fields(v, &allowed)
}

fn strings(v: &Value, key: &str) -> Result<Vec<String>> {
    Ok(b::names(v, key)?
        .into_iter()
        .map(|name| name.to_string())
        .collect())
}

fn selector_binary(v: &Value) -> Result<Selector> {
    let left = registry::selector(b::handle(v, "left")?)?;
    let right = registry::selector(b::handle(v, "right")?)?;
    Ok(match b::string(v, "op")? {
        "union" => left | right,
        "intersection" => left & right,
        "symmetricDifference" => left ^ right,
        "difference" => left - right,
        op => {
            return Err(EngineError::Invalid(format!(
                "unknown selector operation '{op}'"
            )))
        }
    })
}

fn dtype_selector_binary(v: &Value) -> Result<DataTypeSelector> {
    let left = registry::dtype_selector(b::handle(v, "left")?)?;
    let right = registry::dtype_selector(b::handle(v, "right")?)?;
    Ok(match b::string(v, "op")? {
        "union" => left | right,
        "intersection" => left & right,
        "symmetricDifference" => left ^ right,
        "difference" => left - right,
        op => {
            return Err(EngineError::Invalid(format!(
                "unknown datatype selector operation '{op}'"
            )))
        }
    })
}

fn time_units(v: &Value) -> Result<TimeUnitSet> {
    let values = strings(v, "units")?;
    if values.is_empty() {
        return Err(EngineError::Invalid("'units' must not be empty".into()));
    }
    let mut units = TimeUnitSet::empty();
    for value in values {
        units |= match value.as_str() {
            "nanoseconds" => TimeUnitSet::NANO_SECONDS,
            "microseconds" => TimeUnitSet::MICRO_SECONDS,
            "milliseconds" => TimeUnitSet::MILLI_SECONDS,
            _ => return Err(EngineError::Invalid(format!("unknown time unit '{value}'"))),
        };
    }
    Ok(units)
}

fn time_zones(v: &Value) -> Result<TimeZoneSet> {
    let mode = b::string(v, "timeZoneMode")?;
    let zones = if v.get("timeZones").is_some() {
        strings(v, "timeZones")?
    } else {
        Vec::new()
    };
    let requires_zones = matches!(mode, "anyOf" | "unsetOrAnyOf");
    if requires_zones != !zones.is_empty() {
        return Err(EngineError::Invalid(
            "timeZones must be non-empty exactly for anyOf/unsetOrAnyOf".into(),
        ));
    }
    let zones = zones
        .into_iter()
        .map(|zone| {
            TimeZone::opt_try_new(Some(zone))?
                .ok_or_else(|| EngineError::Invalid("time zone must not be empty".into()))
        })
        .collect::<Result<Vec<_>>>()?;
    Ok(match mode {
        "any" => TimeZoneSet::Any,
        "anySet" => TimeZoneSet::AnySet,
        "unset" => TimeZoneSet::Unset,
        "anyOf" => TimeZoneSet::AnyOf(zones.into()),
        "unsetOrAnyOf" => TimeZoneSet::UnsetOrAnyOf(zones.into()),
        _ => {
            return Err(EngineError::Invalid(format!(
                "unknown time zone mode '{mode}'"
            )))
        }
    })
}

fn optional_dtype_selector(v: &Value) -> Result<Option<Arc<DataTypeSelector>>> {
    v.get("inner")
        .map(|_| registry::dtype_selector(b::handle(v, "inner")?).map(Arc::new))
        .transpose()
}

fn create_dtype_selector(v: &Value) -> Result<DataTypeSelector> {
    let kind = b::string(v, "kind")?;
    let allowed: &[&str] = match kind {
        "anyOf" => &["kind", "dtypes"],
        "list" => &["kind", "inner"],
        "array" => &["kind", "inner", "width"],
        "datetime" => &["kind", "units", "timeZoneMode", "timeZones"],
        "duration" => &["kind", "units"],
        _ => &["kind"],
    };
    fields(v, allowed)?;
    Ok(match kind {
        "all" => DataTypeSelector::Wildcard,
        "empty" => DataTypeSelector::Empty,
        "anyOf" => {
            let values = b::req(v, "dtypes")?
                .as_array()
                .ok_or_else(|| EngineError::Invalid("'dtypes' must be an array".into()))?;
            if values.is_empty() || values.len() > 10_000 {
                return Err(EngineError::Invalid(
                    "'dtypes' must contain 1 to 10000 values".into(),
                ));
            }
            DataTypeSelector::AnyOf(
                values
                    .iter()
                    .map(dtype::parse)
                    .collect::<Result<Vec<_>>>()?
                    .into(),
            )
        }
        "integer" => DataTypeSelector::Integer,
        "unsignedInteger" => DataTypeSelector::UnsignedInteger,
        "signedInteger" => DataTypeSelector::SignedInteger,
        "floating" => DataTypeSelector::Float,
        "enum" => DataTypeSelector::Enum,
        "categorical" => DataTypeSelector::Categorical,
        "nested" => DataTypeSelector::Nested,
        "list" => DataTypeSelector::List(optional_dtype_selector(v)?),
        "array" => {
            let width = v
                .get("width")
                .map(|value| {
                    value
                        .as_u64()
                        .filter(|width| *width > 0)
                        .ok_or_else(|| EngineError::Invalid("'width' must be positive".into()))
                        .and_then(|width| {
                            usize::try_from(width)
                                .map_err(|_| EngineError::Invalid("'width' is too large".into()))
                        })
                })
                .transpose()?;
            DataTypeSelector::Array(optional_dtype_selector(v)?, width)
        }
        "struct" => DataTypeSelector::Struct,
        "decimal" => DataTypeSelector::Decimal,
        "numeric" => DataTypeSelector::Numeric,
        "temporal" => DataTypeSelector::Temporal,
        "datetime" => DataTypeSelector::Datetime(time_units(v)?, time_zones(v)?),
        "duration" => DataTypeSelector::Duration(time_units(v)?),
        "object" => DataTypeSelector::Object,
        _ => {
            return Err(EngineError::Invalid(format!(
                "unknown datatype selector kind '{kind}'"
            )))
        }
    })
}

pub fn invoke(command: &str, v: &Value) -> Result<Value> {
    match command {
        "selectorAll" => {
            fields(v, &[])?;
            insert_selector(Selector::Wildcard)
        }
        "selectorEmpty" => {
            fields(v, &[])?;
            insert_selector(Selector::Empty)
        }
        "selectorByName" => {
            fields(v, &["names", "strict", "expandPatterns"])?;
            let names = b::names(v, "names")?;
            if names.is_empty() {
                return Err(EngineError::Invalid("'names' must not be empty".into()));
            }
            insert_selector(polars::lazy::dsl::by_name(
                names,
                b::optional_bool(v, "strict", true)?,
                b::optional_bool(v, "expandPatterns", false)?,
            ))
        }
        "selectorByIndex" => {
            fields(v, &["indices", "strict"])?;
            let values = b::req(v, "indices")?
                .as_array()
                .ok_or_else(|| EngineError::Invalid("'indices' must be an array".into()))?;
            if values.is_empty() || values.len() > 10_000 {
                return Err(EngineError::Invalid(
                    "'indices' must contain 1 to 10000 values".into(),
                ));
            }
            let indices = values
                .iter()
                .map(|value| {
                    value
                        .as_i64()
                        .ok_or_else(|| EngineError::Invalid("indices must be i64 values".into()))
                })
                .collect::<Result<Vec<_>>>()?;
            insert_selector(Selector::ByIndex {
                indices: indices.into(),
                strict: b::optional_bool(v, "strict", true)?,
            })
        }
        "selectorMatches" => {
            fields(v, &["pattern"])?;
            insert_selector(Selector::Matches(b::string(v, "pattern")?.into()))
        }
        "selectorBinary" => {
            fields(v, &["left", "right", "op"])?;
            insert_selector(selector_binary(v)?)
        }
        "selectorNot" => {
            fields(v, &["input"])?;
            insert_selector(!registry::selector(b::handle(v, "input")?)?)
        }
        "selectorAsExpr" => {
            fields(v, &["input"])?;
            let expr = registry::selector(b::handle(v, "input")?)?.as_expr();
            Ok(response(registry::insert(Entry::Expr(expr))?, "expr"))
        }
        "dtypeSelectorCreate" => insert_dtype_selector(create_dtype_selector(v)?),
        "dtypeSelectorBinary" => {
            fields(v, &["left", "right", "op"])?;
            insert_dtype_selector(dtype_selector_binary(v)?)
        }
        "dtypeSelectorNot" => {
            fields(v, &["input"])?;
            insert_dtype_selector(!registry::dtype_selector(b::handle(v, "input")?)?)
        }
        "dtypeSelectorAsSelector" => {
            fields(v, &["input"])?;
            insert_selector(registry::dtype_selector(b::handle(v, "input")?)?.as_selector())
        }
        "dtypeSelectorMatches" => {
            fields(v, &["input", "dtype"])?;
            let selector = registry::dtype_selector(b::handle(v, "input")?)?;
            Ok(json!({"matches": selector.matches(&dtype::parse(b::req(v, "dtype")?)?)}))
        }
        _ => Err(EngineError::Invalid(format!(
            "unknown selector command '{command}'"
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn selector_handles_branch_without_consuming_inputs() {
        let all = registry::insert(Entry::Selector(Selector::Wildcard)).unwrap();
        let numeric = registry::insert(Entry::DataTypeSelector(DataTypeSelector::Numeric)).unwrap();
        let numeric_selector = registry::dtype_selector(numeric).unwrap().as_selector();
        let numeric_selector = registry::insert(Entry::Selector(numeric_selector)).unwrap();
        let difference =
            registry::selector(all).unwrap() - registry::selector(numeric_selector).unwrap();
        assert!(matches!(difference, Selector::Difference(_, _)));
        assert!(registry::selector(all).is_ok());
        assert!(registry::dtype_selector(numeric).is_ok());
        for handle in [all, numeric, numeric_selector] {
            registry::release(handle).unwrap();
        }
    }
}
