//! Numeric and flat time-series expression mappings.
//!
//! Keep feature-gated Polars APIs and their protocol validation together so
//! `bindings.rs` remains the transport's general-purpose mapping layer.

use crate::{
    bindings,
    error::{EngineError, Result},
};
use polars::prelude::*;
use polars::series::ops::NullBehavior;
use serde_json::Value;

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

fn bool_field(v: &Value, key: &str) -> Result<bool> {
    bindings::boolean(v, key)
}

fn optional_bool_field(v: &Value, key: &str, default: bool) -> Result<bool> {
    v.get(key)
        .map(|value| {
            value
                .as_bool()
                .ok_or_else(|| EngineError::Invalid(format!("'{key}' must be boolean")))
        })
        .unwrap_or(Ok(default))
}

fn usize_field(v: &Value, key: &str) -> Result<usize> {
    let raw = bindings::req(v, key)?
        .as_u64()
        .ok_or_else(|| EngineError::Invalid(format!("'{key}' must be unsigned")))?;
    usize::try_from(raw).map_err(|_| EngineError::Invalid(format!("'{key}' is too large")))
}

fn rolling_options(v: &Value) -> Result<RollingOptionsFixedWindow> {
    let window_size = usize_field(v, "windowSize")?;
    let min_periods = usize_field(v, "minPeriods")?;
    if window_size == 0 || min_periods > window_size {
        return Err(EngineError::Invalid(
            "windowSize must be positive and >= minPeriods".into(),
        ));
    }
    let weights = v
        .get("weights")
        .map(|raw| {
            let values = raw
                .as_array()
                .ok_or_else(|| EngineError::Invalid("'weights' must be an array".into()))?;
            if values.len() != window_size {
                return Err(EngineError::Invalid(
                    "weights length must equal windowSize".into(),
                ));
            }
            values
                .iter()
                .map(|value| {
                    value.as_f64().filter(|x| x.is_finite()).ok_or_else(|| {
                        EngineError::Invalid("weights must contain finite numbers".into())
                    })
                })
                .collect::<Result<Vec<_>>>()
        })
        .transpose()?;
    Ok(RollingOptionsFixedWindow {
        window_size,
        min_periods,
        weights,
        center: bool_field(v, "center")?,
        fn_params: None,
    })
}

fn ewm_options(v: &Value) -> Result<EWMOptions> {
    let alpha = bindings::req(v, "alpha")?
        .as_f64()
        .filter(|x| x.is_finite() && *x > 0.0 && *x <= 1.0)
        .ok_or_else(|| EngineError::Invalid("alpha must be in (0, 1]".into()))?;
    Ok(EWMOptions {
        alpha,
        adjust: optional_bool_field(v, "adjust", true)?,
        bias: optional_bool_field(v, "bias", false)?,
        min_periods: usize_field(v, "minPeriods")?,
        ignore_nulls: bool_field(v, "ignoreNulls")?,
    })
}

/// Dispatch an advanced function, returning `None` for functions owned by the
/// general binding module.
pub fn function(v: &Value, name: &str, x: Expr, mut arguments: Vec<Expr>) -> Result<Option<Expr>> {
    let options: &[&str] = match name {
        "rank" => &["method", "descending"],
        "interpolate" => &["method"],
        "diff" => &["nullBehavior"],
        "rollingMin" | "rollingMax" | "rollingMean" | "rollingSum" | "rollingMedian"
        | "rollingVariance" | "rollingStd" => &["windowSize", "minPeriods", "weights", "center"],
        "ewmMean" => &["alpha", "adjust", "minPeriods", "ignoreNulls"],
        "ewmSum" => &["alpha", "minPeriods", "ignoreNulls"],
        "ewmStd" | "ewmVariance" => &["alpha", "adjust", "bias", "minPeriods", "ignoreNulls"],
        "pow" | "sqrt" | "cbrt" | "log" | "log1p" | "exp" | "sin" | "cos" | "tan" | "cot"
        | "asin" | "acos" | "atan" | "atan2" | "sinh" | "cosh" | "tanh" | "asinh" | "acosh"
        | "atanh" | "degrees" | "radians" | "interpolateBy" | "pctChange" => &[],
        _ => return Ok(None),
    };
    let mut allowed = BASE_FIELDS.to_vec();
    allowed.extend(options);
    bindings::validate_fields(v, &allowed)?;

    let expression = match name {
        "pow" => {
            exact(name, &arguments, 1)?;
            x.pow(arguments.remove(0))
        }
        "log" => {
            exact(name, &arguments, 1)?;
            x.log(arguments.remove(0))
        }
        "atan2" => {
            exact(name, &arguments, 1)?;
            x.arctan2(arguments.remove(0))
        }
        "interpolateBy" => {
            exact(name, &arguments, 1)?;
            x.interpolate_by(arguments.remove(0))
        }
        "diff" => {
            exact(name, &arguments, 1)?;
            let behavior = match bindings::string(v, "nullBehavior")? {
                "ignore" => NullBehavior::Ignore,
                "drop" => NullBehavior::Drop,
                value => {
                    return Err(EngineError::Invalid(format!(
                        "unknown nullBehavior '{value}'"
                    )))
                }
            };
            x.diff(arguments.remove(0), behavior)
        }
        "pctChange" => {
            exact(name, &arguments, 1)?;
            x.pct_change(arguments.remove(0))
        }
        "sqrt" | "cbrt" | "log1p" | "exp" | "sin" | "cos" | "tan" | "cot" | "asin" | "acos"
        | "atan" | "sinh" | "cosh" | "tanh" | "asinh" | "acosh" | "atanh" | "degrees"
        | "radians" => {
            exact(name, &arguments, 0)?;
            match name {
                "sqrt" => x.sqrt(),
                "cbrt" => x.cbrt(),
                "log1p" => x.log1p(),
                "exp" => x.exp(),
                "sin" => x.sin(),
                "cos" => x.cos(),
                "tan" => x.tan(),
                "cot" => x.cot(),
                "asin" => x.arcsin(),
                "acos" => x.arccos(),
                "atan" => x.arctan(),
                "sinh" => x.sinh(),
                "cosh" => x.cosh(),
                "tanh" => x.tanh(),
                "asinh" => x.arcsinh(),
                "acosh" => x.arccosh(),
                "atanh" => x.arctanh(),
                "degrees" => x.degrees(),
                "radians" => x.radians(),
                _ => unreachable!(),
            }
        }
        "rank" => {
            exact(name, &arguments, 0)?;
            let method = match bindings::string(v, "method")? {
                "average" => RankMethod::Average,
                "min" => RankMethod::Min,
                "max" => RankMethod::Max,
                "dense" => RankMethod::Dense,
                "ordinal" => RankMethod::Ordinal,
                value => {
                    return Err(EngineError::Invalid(format!(
                        "unknown rank method '{value}'"
                    )))
                }
            };
            x.rank(
                RankOptions {
                    method,
                    descending: bool_field(v, "descending")?,
                },
                None,
            )
        }
        "interpolate" => {
            exact(name, &arguments, 0)?;
            let method = match bindings::string(v, "method")? {
                "linear" => InterpolationMethod::Linear,
                "nearest" => InterpolationMethod::Nearest,
                value => {
                    return Err(EngineError::Invalid(format!(
                        "unknown interpolation method '{value}'"
                    )))
                }
            };
            x.interpolate(method)
        }
        "rollingMin" | "rollingMax" | "rollingMean" | "rollingSum" | "rollingMedian"
        | "rollingVariance" | "rollingStd" => {
            exact(name, &arguments, 0)?;
            let options = rolling_options(v)?;
            match name {
                "rollingMin" => x.rolling_min(options),
                "rollingMax" => x.rolling_max(options),
                "rollingMean" => x.rolling_mean(options),
                "rollingSum" => x.rolling_sum(options),
                "rollingMedian" => x.rolling_median(options),
                "rollingVariance" => x.rolling_var(options),
                "rollingStd" => x.rolling_std(options),
                _ => unreachable!(),
            }
        }
        "ewmMean" | "ewmSum" | "ewmStd" | "ewmVariance" => {
            exact(name, &arguments, 0)?;
            let options = ewm_options(v)?;
            match name {
                "ewmMean" => x.ewm_mean(options),
                "ewmSum" => x.ewm_sum(options),
                "ewmStd" => x.ewm_std(options),
                "ewmVariance" => x.ewm_var(options),
                _ => unreachable!(),
            }
        }
        _ => unreachable!(),
    };
    Ok(Some(expression))
}

pub fn aggregate(v: &Value, op: &str, x: Expr) -> Result<Option<Expr>> {
    let expression = match op {
        "argMin" => x.arg_min(),
        "argMax" => x.arg_max(),
        "approximateNUnique" => x.approx_n_unique(),
        "nanMin" => x.nan_min(),
        "nanMax" => x.nan_max(),
        "mode" => x.mode(bool_field(v, "maintainOrder")?),
        "skew" => x.skew(bool_field(v, "bias")?),
        "kurtosis" => x.kurtosis(bool_field(v, "fisher")?, bool_field(v, "bias")?),
        "any" => x.any(bool_field(v, "ignoreNulls")?),
        "all" => x.all(bool_field(v, "ignoreNulls")?),
        _ => return Ok(None),
    };
    Ok(Some(expression))
}

#[cfg(test)]
mod tests {
    use super::*;
    use polars::lazy::dsl::lit;
    use serde_json::json;

    #[test]
    fn advanced_function_schemas_are_closed() {
        let valid = json!({
            "protocol": 2, "command": "exprFunction", "input": "1",
            "name": "rank", "arguments": [], "method": "dense",
            "descending": false
        });
        assert!(function(&valid, "rank", lit(1), vec![]).unwrap().is_some());

        let mut invalid = valid;
        invalid["bias"] = json!(true);
        assert!(function(&invalid, "rank", lit(1), vec![]).is_err());
    }

    #[test]
    fn rolling_validation_precedes_polars_execution() {
        let invalid = json!({
            "protocol": 2, "command": "exprFunction", "input": "1",
            "name": "rollingMean", "arguments": [], "windowSize": 2,
            "minPeriods": 3, "center": false
        });
        assert!(function(&invalid, "rollingMean", lit(1), vec![]).is_err());
    }
}
