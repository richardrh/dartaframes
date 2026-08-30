//! Temporal grouping, advanced joins, and window expression mappings.

use crate::{
    bindings,
    error::{EngineError, Result},
    registry,
};
use polars::prelude::*;
use serde_json::Value;

fn optional_string<'a>(v: &'a Value, key: &str) -> Result<Option<&'a str>> {
    v.get(key)
        .map(|value| {
            value
                .as_str()
                .ok_or_else(|| EngineError::Invalid(format!("'{key}' must be a string")))
        })
        .transpose()
}

fn duration(v: &Value, key: &str) -> Result<Duration> {
    Duration::try_parse(bindings::string(v, key)?)
        .map_err(|error| EngineError::Invalid(format!("invalid '{key}': {error}")))
}

fn optional_duration(v: &Value, key: &str) -> Result<Option<Duration>> {
    optional_string(v, key)?
        .map(|value| {
            Duration::try_parse(value)
                .map_err(|error| EngineError::Invalid(format!("invalid '{key}': {error}")))
        })
        .transpose()
}

fn closed(v: &Value) -> Result<ClosedWindow> {
    Ok(match bindings::string(v, "closed")? {
        "left" => ClosedWindow::Left,
        "right" => ClosedWindow::Right,
        "both" => ClosedWindow::Both,
        "none" => ClosedWindow::None,
        value => {
            return Err(EngineError::Invalid(format!(
                "unknown closed window '{value}'"
            )))
        }
    })
}

fn coalesce(v: &Value) -> Result<JoinCoalesce> {
    match v.get("coalesce") {
        None => Ok(JoinCoalesce::JoinSpecific),
        Some(Value::Null) => Ok(JoinCoalesce::JoinSpecific),
        Some(value) => match value.as_bool() {
            Some(true) => Ok(JoinCoalesce::CoalesceColumns),
            Some(false) => Ok(JoinCoalesce::KeepColumns),
            None => Err(EngineError::Invalid("'coalesce' must be a boolean".into())),
        },
    }
}

fn parallel(v: &Value) -> Result<(bool, bool)> {
    let allow = bindings::boolean(v, "allowParallel")?;
    let force = bindings::boolean(v, "forceParallel")?;
    if force && !allow {
        return Err(EngineError::Invalid(
            "forceParallel requires allowParallel".into(),
        ));
    }
    Ok((allow, force))
}

fn asof(v: &Value) -> Result<LazyFrame> {
    let left = registry::lazy_frame(bindings::handle(v, "left")?)?;
    let right = registry::lazy_frame(bindings::handle(v, "right")?)?;
    let left_on = registry::expr(bindings::handle(v, "leftOn")?)?;
    let right_on = registry::expr(bindings::handle(v, "rightOn")?)?;
    let left_by = v
        .get("leftBy")
        .map(|_| bindings::names(v, "leftBy"))
        .transpose()?;
    let right_by = v
        .get("rightBy")
        .map(|_| bindings::names(v, "rightBy"))
        .transpose()?;
    if left_by.is_some() != right_by.is_some()
        || left_by.as_ref().map(Vec::len) != right_by.as_ref().map(Vec::len)
    {
        return Err(EngineError::Invalid(
            "leftBy and rightBy must have equal lengths".into(),
        ));
    }
    let tolerance = optional_string(v, "tolerance")?;
    if let Some(value) = tolerance {
        // Polars 0.55.2 accepts index-count durations such as `10i` here but
        // later panics while converting the string tolerance for integer join
        // keys. This binding does not yet expose AsOfOptions' scalar tolerance,
        // so reject index-count tolerances at the protocol boundary instead of
        // allowing user input to reach that upstream panic path.
        if value.contains('i') {
            return Err(EngineError::Invalid(
                "as-of string tolerance must use temporal units; integer-key tolerance is not yet supported"
                    .into(),
            ));
        }
        Duration::try_parse(value)
            .map_err(|error| EngineError::Invalid(format!("invalid 'tolerance': {error}")))?;
    }
    let options = AsOfOptions {
        strategy: match bindings::string(v, "strategy")? {
            "backward" => AsofStrategy::Backward,
            "forward" => AsofStrategy::Forward,
            "nearest" => AsofStrategy::Nearest,
            value => {
                return Err(EngineError::Invalid(format!(
                    "unknown asof strategy '{value}'"
                )))
            }
        },
        tolerance: None,
        tolerance_str: tolerance.map(Into::into),
        left_by,
        right_by,
        allow_eq: bindings::boolean(v, "allowEqual")?,
        check_sortedness: bindings::boolean(v, "checkSortedness")?,
    };
    let (allow_parallel, force_parallel) = parallel(v)?;
    Ok(left
        .join_builder()
        .with(right)
        .left_on([left_on])
        .right_on([right_on])
        .how(JoinType::AsOf(Box::new(options)))
        .suffix(bindings::string(v, "suffix")?)
        .coalesce(coalesce(v)?)
        .allow_parallel(allow_parallel)
        .force_parallel(force_parallel)
        .finish())
}

fn join_where(v: &Value) -> Result<LazyFrame> {
    let predicates = bindings::exprs(v, "predicates")?;
    if predicates.is_empty() {
        return Err(EngineError::Invalid("predicates must not be empty".into()));
    }
    let (allow_parallel, force_parallel) = parallel(v)?;
    Ok(registry::lazy_frame(bindings::handle(v, "left")?)?
        .join_builder()
        .with(registry::lazy_frame(bindings::handle(v, "right")?)?)
        .suffix(bindings::string(v, "suffix")?)
        .allow_parallel(allow_parallel)
        .force_parallel(force_parallel)
        .join_where(predicates))
}

fn dynamic_group(v: &Value) -> Result<LazyFrame> {
    let every = duration(v, "every")?;
    let options = DynamicGroupOptions {
        index_column: "".into(),
        every,
        period: optional_duration(v, "period")?.unwrap_or(every),
        offset: optional_duration(v, "offset")?.unwrap_or_else(|| Duration::new(0)),
        label: match bindings::string(v, "label")? {
            "left" => Label::Left,
            "right" => Label::Right,
            "dataPoint" => Label::DataPoint,
            value => {
                return Err(EngineError::Invalid(format!(
                    "unknown dynamic label '{value}'"
                )))
            }
        },
        include_boundaries: bindings::boolean(v, "includeBoundaries")?,
        closed_window: closed(v)?,
        start_by: match bindings::string(v, "startBy")? {
            "windowBound" => StartBy::WindowBound,
            "dataPoint" => StartBy::DataPoint,
            "monday" => StartBy::Monday,
            "tuesday" => StartBy::Tuesday,
            "wednesday" => StartBy::Wednesday,
            "thursday" => StartBy::Thursday,
            "friday" => StartBy::Friday,
            "saturday" => StartBy::Saturday,
            "sunday" => StartBy::Sunday,
            value => return Err(EngineError::Invalid(format!("unknown startBy '{value}'"))),
        },
    };
    Ok(registry::lazy_frame(bindings::handle(v, "input")?)?
        .group_by_dynamic(
            registry::expr(bindings::handle(v, "indexColumn")?)?,
            bindings::exprs(v, "groupBy")?,
            options,
        )
        .agg(bindings::exprs(v, "aggregations")?))
}

fn rolling_group(v: &Value) -> Result<LazyFrame> {
    let period = duration(v, "period")?;
    let options = RollingGroupOptions {
        index_column: "".into(),
        period,
        offset: optional_duration(v, "offset")?.unwrap_or(-period),
        closed_window: closed(v)?,
    };
    Ok(registry::lazy_frame(bindings::handle(v, "input")?)?
        .rolling(
            registry::expr(bindings::handle(v, "indexColumn")?)?,
            bindings::exprs(v, "groupBy")?,
            options,
        )
        .agg(bindings::exprs(v, "aggregations")?))
}

pub fn lazy(v: &Value, command: &str) -> Result<LazyFrame> {
    match command {
        "lazyJoinAsOf" => asof(v),
        "lazyJoinWhere" => join_where(v),
        "lazyGroupByDynamic" => dynamic_group(v),
        "lazyGroupByRolling" => rolling_group(v),
        _ => Err(EngineError::Invalid(format!("unknown command '{command}'"))),
    }
}

pub fn over(v: &Value) -> Result<Expr> {
    let partition_by = bindings::exprs(v, "partitionBy")?;
    let order_by = bindings::exprs(v, "orderBy")?;
    if partition_by.is_empty() && order_by.is_empty() {
        return Err(EngineError::Invalid(
            "partitionBy and orderBy must not both be empty".into(),
        ));
    }
    let order = if order_by.is_empty() {
        None
    } else {
        Some((
            order_by,
            SortOptions {
                descending: bindings::boolean(v, "orderDescending")?,
                nulls_last: bindings::boolean(v, "orderNullsLast")?,
                maintain_order: bindings::boolean(v, "orderMaintainOrder")?,
                multithreaded: bindings::boolean(v, "orderMultithreaded")?,
                limit: None,
            },
        ))
    };
    let mapping = match bindings::string(v, "mapping")? {
        "groupsToRows" => WindowMapping::GroupsToRows,
        "explode" => WindowMapping::Explode,
        "join" => WindowMapping::Join,
        value => {
            return Err(EngineError::Invalid(format!(
                "unknown window mapping '{value}'"
            )))
        }
    };
    registry::expr(bindings::handle(v, "input")?)?
        .over_with_options(
            (!partition_by.is_empty()).then_some(partition_by),
            order,
            mapping,
        )
        .map_err(Into::into)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn window_schema_values_are_validated() {
        let request = json!({
            "input":"1", "partitionBy":[], "orderBy":[],
            "mapping":"groupsToRows", "orderDescending":false,
            "orderNullsLast":false, "orderMaintainOrder":false,
            "orderMultithreaded":true
        });
        assert!(over(&request).is_err());
        assert!(Duration::try_parse("not-a-duration").is_err());
    }
}
