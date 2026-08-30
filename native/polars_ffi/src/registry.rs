use crate::error::{EngineError, Result};
use parking_lot::Mutex;
use polars::prelude::*;
use polars::sql::SQLContext;
use std::sync::{Arc, OnceLock};

pub type Handle = u64;

pub enum Entry {
    Expr(Expr),
    Selector(Selector),
    DataTypeSelector(DataTypeSelector),
    LazyFrame(Box<LazyFrame>),
    Frame(DataFrame),
    Series(Series),
    Job(Arc<crate::jobs::Job>),
    SqlContext(Arc<Mutex<SQLContext>>),
    BatchStream(Arc<crate::batch_stream::BatchStream>),
}

struct Slot {
    generation: u32,
    value: Option<Entry>,
}
#[derive(Default)]
struct Registry {
    slots: Vec<Slot>,
    free: Vec<u32>,
}

static REGISTRY: OnceLock<Mutex<Registry>> = OnceLock::new();
fn registry() -> &'static Mutex<Registry> {
    REGISTRY.get_or_init(Default::default)
}

fn encode(index: u32, generation: u32) -> Handle {
    ((generation as u64) << 32) | (index as u64 + 1)
}
fn decode(handle: Handle) -> Result<(usize, u32)> {
    let low = handle as u32;
    let generation = (handle >> 32) as u32;
    if low == 0 || generation == 0 {
        return Err(EngineError::Handle("invalid zero handle".into()));
    }
    Ok(((low - 1) as usize, generation))
}

pub fn insert(value: Entry) -> Result<Handle> {
    Ok(insert_many(vec![value])?.remove(0))
}

/// Inserts related results while holding the registry lock. Capacity is
/// checked before any slot is changed, so callers never observe half a result.
pub fn insert_many(values: Vec<Entry>) -> Result<Vec<Handle>> {
    let mut r = registry().lock();
    let additional = values.len().saturating_sub(r.free.len());
    if r.slots.len().checked_add(additional).is_none()
        || r.slots.len() + additional > u32::MAX as usize
    {
        return Err(EngineError::Internal(
            "native handle registry exhausted".into(),
        ));
    }
    let mut handles = Vec::with_capacity(values.len());
    for value in values {
        let index = if let Some(i) = r.free.pop() {
            i
        } else {
            let i = r.slots.len() as u32;
            r.slots.push(Slot {
                generation: 1,
                value: None,
            });
            i
        };
        let slot = &mut r.slots[index as usize];
        slot.value = Some(value);
        handles.push(encode(index, slot.generation));
    }
    Ok(handles)
}

pub fn diagnostics() -> serde_json::Value {
    let r = registry().lock();
    let mut by_kind = std::collections::BTreeMap::<&str, usize>::new();
    for entry in r.slots.iter().filter_map(|slot| slot.value.as_ref()) {
        let kind = match entry {
            Entry::Expr(_) => "expr",
            Entry::Selector(_) => "selector",
            Entry::DataTypeSelector(_) => "dtypeSelector",
            Entry::LazyFrame(_) => "lazyFrame",
            Entry::Frame(_) => "frame",
            Entry::Series(_) => "series",
            Entry::Job(_) => "job",
            Entry::SqlContext(_) => "sqlContext",
            Entry::BatchStream(_) => "batchStream",
        };
        *by_kind.entry(kind).or_default() += 1;
    }
    serde_json::json!({
        "activeHandles": by_kind.values().sum::<usize>(),
        "handlesByKind": by_kind,
        "slotCapacity": r.slots.len(),
        "reusableSlots": r.free.len(),
    })
}

fn get<T>(handle: Handle, kind: &str, clone: impl FnOnce(&Entry) -> Option<T>) -> Result<T> {
    let (i, generation) = decode(handle)?;
    let r = registry().lock();
    let slot = r
        .slots
        .get(i)
        .filter(|s| s.generation == generation)
        .ok_or_else(|| EngineError::Handle(format!("stale or unknown {kind} handle")))?;
    match slot.value.as_ref() {
        Some(value) => clone(value)
            .ok_or_else(|| EngineError::Handle(format!("handle does not refer to a {kind}"))),
        None => Err(EngineError::Handle(format!("released {kind} handle"))),
    }
}

pub fn expr(handle: Handle) -> Result<Expr> {
    get(handle, "expression", |value| match value {
        Entry::Expr(v) => Some(v.clone()),
        _ => None,
    })
}

pub fn expr_input(handle: Handle) -> Result<Expr> {
    get(handle, "expression input", |value| match value {
        Entry::Expr(v) => Some(v.clone()),
        Entry::Selector(v) => Some(v.clone().as_expr()),
        _ => None,
    })
}

pub fn selector(handle: Handle) -> Result<Selector> {
    get(handle, "selector", |value| match value {
        Entry::Selector(v) => Some(v.clone()),
        _ => None,
    })
}

pub fn dtype_selector(handle: Handle) -> Result<DataTypeSelector> {
    get(handle, "datatype selector", |value| match value {
        Entry::DataTypeSelector(v) => Some(v.clone()),
        _ => None,
    })
}

pub fn lazy_frame(handle: Handle) -> Result<LazyFrame> {
    get(handle, "lazy frame", |value| match value {
        Entry::LazyFrame(v) => Some(v.as_ref().clone()),
        _ => None,
    })
}

pub fn frame(handle: Handle) -> Result<DataFrame> {
    get(handle, "frame", |value| match value {
        Entry::Frame(v) => Some(v.clone()),
        _ => None,
    })
}

pub fn series(handle: Handle) -> Result<Series> {
    get(handle, "series", |value| match value {
        Entry::Series(v) => Some(v.clone()),
        _ => None,
    })
}

pub fn job(handle: Handle) -> Result<Arc<crate::jobs::Job>> {
    get(handle, "job", |value| match value {
        Entry::Job(v) => Some(v.clone()),
        _ => None,
    })
}

pub fn sql_context(handle: Handle) -> Result<Arc<Mutex<SQLContext>>> {
    get(handle, "SQL context", |value| match value {
        Entry::SqlContext(v) => Some(v.clone()),
        _ => None,
    })
}

pub fn batch_stream(handle: Handle) -> Result<Arc<crate::batch_stream::BatchStream>> {
    get(handle, "batch stream", |value| match value {
        Entry::BatchStream(v) => Some(v.clone()),
        _ => None,
    })
}

pub fn release(handle: Handle) -> Result<()> {
    let (i, generation) = decode(handle)?;
    let mut r = registry().lock();
    let slot = r
        .slots
        .get_mut(i)
        .filter(|s| s.generation == generation)
        .ok_or_else(|| EngineError::Handle("stale or unknown handle".into()))?;
    if slot.value.take().is_none() {
        return Err(EngineError::Handle("handle already released".into()));
    }
    // Never wrap a generation: doing so could make a very old handle valid.
    if slot.generation != u32::MAX {
        slot.generation += 1;
        r.free
            .push(u32::try_from(i).expect("decoded registry index exceeds u32"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maximum_generation_retires_slot() {
        let handle = insert(Entry::Frame(DataFrame::empty())).unwrap();
        let (index, _) = decode(handle).unwrap();
        let max_handle = {
            let mut registry = registry().lock();
            registry.slots[index].generation = u32::MAX;
            encode(u32::try_from(index).unwrap(), u32::MAX)
        };
        release(max_handle).unwrap();
        let registry = registry().lock();
        assert!(registry.slots[index].value.is_none());
        assert_eq!(registry.slots[index].generation, u32::MAX);
        assert!(!registry.free.contains(&u32::try_from(index).unwrap()));
        drop(registry);
        assert!(decode(0).is_err());
        assert!(frame(max_handle).is_err());
    }

    #[test]
    fn all_kinds_are_typed_generation_safe_and_independent() {
        let frame_handle = insert(Entry::Frame(DataFrame::empty())).unwrap();
        let lazy = insert(Entry::LazyFrame(Box::new(
            frame(frame_handle).unwrap().lazy(),
        )))
        .unwrap();
        let expr = insert(Entry::Expr(col("x"))).unwrap();
        let selector = insert(Entry::Selector(Selector::Wildcard)).unwrap();
        let dtype_selector = insert(Entry::DataTypeSelector(DataTypeSelector::Numeric)).unwrap();
        let series_handle = insert(Entry::Series(Series::new("x".into(), [1_i32]))).unwrap();
        let job = insert(Entry::Job(
            crate::jobs::Job::submit(DataFrame::empty().lazy(), Engine::Auto).unwrap(),
        ))
        .unwrap();
        let sql_context =
            insert(Entry::SqlContext(Arc::new(Mutex::new(SQLContext::new())))).unwrap();
        assert!(self::frame(frame_handle).is_ok());
        assert!(lazy_frame(lazy).is_ok());
        assert!(self::expr(expr).is_ok());
        assert!(self::selector(selector).is_ok());
        assert!(self::dtype_selector(dtype_selector).is_ok());
        assert!(self::series(series_handle).is_ok());
        assert!(self::job(job).is_ok());
        assert!(self::sql_context(sql_context).is_ok());
        assert!(self::frame(expr).is_err());
        assert!(self::series(frame_handle).is_err());
        release(frame_handle).unwrap();
        assert!(self::frame(frame_handle).is_err());
        assert!(
            lazy_frame(lazy).is_ok(),
            "derived value must own its native clone"
        );
        assert!(release(frame_handle).is_err());
        release(lazy).unwrap();
        release(expr).unwrap();
        release(selector).unwrap();
        release(dtype_selector).unwrap();
        release(series_handle).unwrap();
        release(job).unwrap();
        release(sql_context).unwrap();
    }
}
