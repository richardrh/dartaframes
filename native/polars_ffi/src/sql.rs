use crate::{
    bindings as b,
    error::{EngineError, Result},
    registry::{self, Entry},
};
use parking_lot::Mutex;
use polars::sql::SQLContext;
use serde_json::{json, Value};
use std::sync::Arc;

fn response(handle: u64, kind: &str) -> Value {
    json!({"handle": handle.to_string(), "kind": kind})
}

fn fields(v: &Value, extra: &[&str]) -> Result<()> {
    let mut allowed = vec!["protocol", "command"];
    allowed.extend(extra);
    b::validate_fields(v, &allowed)
}

fn context(v: &Value) -> Result<Arc<Mutex<SQLContext>>> {
    registry::sql_context(b::handle(v, "context")?)
}

fn names(v: &Value) -> Result<Vec<String>> {
    Ok(b::names(v, "names")?
        .into_iter()
        .map(|name| name.to_string())
        .collect())
}

pub fn invoke(command: &str, v: &Value) -> Result<Value> {
    match command {
        "sqlContextNew" => {
            fields(v, &[])?;
            Ok(response(
                registry::insert(Entry::SqlContext(Arc::new(Mutex::new(SQLContext::new()))))?,
                "sqlContext",
            ))
        }
        "sqlContextRegister" => {
            fields(v, &["context", "name", "input"])?;
            let frame = registry::lazy_frame(b::handle(v, "input")?)?;
            context(v)?.lock().register(b::string(v, "name")?, frame);
            Ok(json!({"registered": true}))
        }
        "sqlContextRegisterAll" => {
            fields(v, &["context", "tables"])?;
            let tables = b::req(v, "tables")?
                .as_array()
                .ok_or_else(|| EngineError::Invalid("'tables' must be an array".into()))?;
            if tables.len() > 10_000 {
                return Err(EngineError::Invalid("too many tables".into()));
            }
            // Resolve every frame before mutating the context.
            let resolved = tables
                .iter()
                .map(|table| {
                    b::validate_fields(table, &["name", "input"])?;
                    Ok((
                        b::string(table, "name")?.to_owned(),
                        registry::lazy_frame(b::handle(table, "input")?)?,
                    ))
                })
                .collect::<Result<Vec<_>>>()?;
            let context = context(v)?;
            let context = context.lock();
            for (name, frame) in resolved {
                context.register(&name, frame);
            }
            Ok(json!({"registered": tables.len()}))
        }
        "sqlContextUnregister" => {
            fields(v, &["context", "names"])?;
            let names = names(v)?;
            let context = context(v)?;
            let context = context.lock();
            for name in &names {
                context.unregister(name);
            }
            Ok(json!({"unregistered": names.len()}))
        }
        "sqlContextTables" => {
            fields(v, &["context"])?;
            Ok(json!({"tables": context(v)?.lock().get_tables()}))
        }
        "sqlContextExecute" => {
            fields(v, &["context", "query"])?;
            let query = b::string(v, "query")?;
            let frame = context(v)?.lock().execute(query)?;
            Ok(response(
                registry::insert(Entry::LazyFrame(Box::new(frame)))?,
                "lazyFrame",
            ))
        }
        _ => Err(EngineError::Invalid(format!(
            "unknown SQL command '{command}'"
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use polars::{df, prelude::IntoLazy};

    #[test]
    fn registered_source_and_result_are_independent() {
        let context = Arc::new(Mutex::new(SQLContext::new()));
        let source = df!("x" => [1_i32, 2]).unwrap().lazy();
        context.lock().register("source", source);
        let result = context
            .lock()
            .execute("SELECT x FROM source WHERE x > 1")
            .unwrap();
        drop(context);
        assert_eq!(result.collect().unwrap().height(), 1);
    }
}
