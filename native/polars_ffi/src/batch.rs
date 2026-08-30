use crate::{
    dtype,
    error::{EngineError, Result},
};
use base64::Engine;
use polars::prelude::*;
use polars_utils::float16::pf16;
use serde_json::{json, Value};

fn values(column: &Value) -> Result<&[Value]> {
    column
        .get("values")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .ok_or_else(|| EngineError::Invalid("column.values must be an array".into()))
}
fn int(v: &Value) -> Result<i128> {
    if let Some(n) = v.as_i64() {
        return Ok(n as i128);
    }
    if let Some(n) = v.as_u64() {
        return Ok(n as i128);
    }
    if let Some(n) = v.get("value").and_then(Value::as_i64) {
        return Ok(n as i128);
    }
    if let Some(n) = v.get("value").and_then(Value::as_u64) {
        return Ok(n as i128);
    }
    let s = v
        .as_str()
        .or_else(|| v.get("value").and_then(Value::as_str))
        .or_else(|| v.get("unscaled").and_then(Value::as_str))
        .ok_or_else(|| {
            EngineError::Invalid("integer value must be a number or decimal string".into())
        })?;
    s.parse()
        .map_err(|_| EngineError::Invalid(format!("invalid integer '{s}'")))
}
fn uint(v: &Value) -> Result<u128> {
    if let Some(n) = v.as_u64() {
        return Ok(n as u128);
    }
    if let Some(n) = v.get("value").and_then(Value::as_u64) {
        return Ok(n as u128);
    }
    let s = v
        .as_str()
        .or_else(|| v.get("value").and_then(Value::as_str))
        .ok_or_else(|| {
            EngineError::Invalid("unsigned integer must be a number or decimal string".into())
        })?;
    s.parse()
        .map_err(|_| EngineError::Invalid(format!("invalid unsigned integer '{s}'")))
}
fn float(v: &Value, bits: u32) -> Result<f64> {
    if let Some(n) = v.as_f64() {
        return Ok(n);
    }
    if let Some(n) = v.get("value").and_then(Value::as_f64) {
        return Ok(n);
    }
    if let Some(s) = v.get("floatBits").and_then(Value::as_str) {
        let expected = if bits == 32 { 8 } else { 16 };
        if s.len() != expected {
            return Err(EngineError::Invalid(format!(
                "Float{bits} floatBits must contain exactly {expected} hexadecimal digits"
            )));
        }
        return if bits == 32 {
            u32::from_str_radix(s, 16).map(|n| f32::from_bits(n) as f64)
        } else {
            u64::from_str_radix(s, 16).map(f64::from_bits)
        }
        .map_err(|_| EngineError::Invalid("invalid floatBits".into()));
    }
    Err(EngineError::Invalid(
        "float value must be numeric or floatBits".into(),
    ))
}

fn float16(v: &Value) -> Result<pf16> {
    if let Some(s) = v.get("floatBits").and_then(Value::as_str) {
        if s.len() != 4 {
            return Err(EngineError::Invalid(
                "Float16 floatBits must contain exactly four hexadecimal digits".into(),
            ));
        }
        return u16::from_str_radix(s, 16)
            .map(pf16::from_bits)
            .map_err(|_| EngineError::Invalid("invalid Float16 floatBits".into()));
    }
    float(v, 16).map(pf16::from)
}

pub fn import(batch: &Value) -> Result<DataFrame> {
    let object = batch
        .as_object()
        .ok_or_else(|| EngineError::Invalid("batch must be an object".into()))?;
    if object.keys().any(|key| key != "length" && key != "columns") {
        return Err(EngineError::Invalid("unknown batch field".into()));
    }
    let cols = batch
        .get("columns")
        .and_then(Value::as_array)
        .ok_or_else(|| EngineError::Invalid("batch.columns must be an array".into()))?;
    if cols.len() > 100_000 {
        return Err(EngineError::Invalid("too many columns".into()));
    }
    let declared_height = match batch.get("length") {
        None => None,
        Some(value) => {
            let length = value.as_u64().ok_or_else(|| {
                EngineError::Invalid("batch.length must be a non-negative integer".into())
            })?;
            Some(usize::try_from(length).map_err(|_| {
                EngineError::Invalid("batch.length does not fit this platform".into())
            })?)
        }
    };
    let mut out = Vec::with_capacity(cols.len());
    let mut height = declared_height;
    for c in cols {
        let object = c
            .as_object()
            .ok_or_else(|| EngineError::Invalid("column must be an object".into()))?;
        if object
            .keys()
            .any(|key| !["name", "dtype", "values", "validity"].contains(&key.as_str()))
        {
            return Err(EngineError::Invalid("unknown column field".into()));
        }
        let name: PlSmallStr = c
            .get("name")
            .and_then(Value::as_str)
            .filter(|name| !name.is_empty())
            .ok_or_else(|| EngineError::Invalid("column.name must be a string".into()))?
            .into();
        let raw = values(c)?;
        let validity = c
            .get("validity")
            .map(|x| {
                x.as_array()
                    .ok_or_else(|| EngineError::Invalid("column.validity must be an array".into()))
            })
            .transpose()?;
        if validity.is_some_and(|a| a.len() != raw.len()) {
            return Err(EngineError::Invalid(
                "validity length differs from values length".into(),
            ));
        }
        if let Some(validity) = validity {
            if validity.iter().any(|v| !v.is_boolean()) {
                return Err(EngineError::Invalid(
                    "column.validity values must be booleans".into(),
                ));
            }
        }
        let normalized;
        let vs = if let Some(validity) = validity {
            normalized = raw
                .iter()
                .zip(validity)
                .map(|(v, valid)| {
                    if valid.as_bool() == Some(false) {
                        Value::Null
                    } else {
                        v.clone()
                    }
                })
                .collect::<Vec<_>>();
            normalized.as_slice()
        } else {
            raw
        };
        if let Some(expected) = height {
            if expected != vs.len() {
                return Err(EngineError::Invalid(
                    "column length differs from batch.length or another column".into(),
                ));
            }
        } else {
            height = Some(vs.len());
        }
        let dtv = c
            .get("dtype")
            .ok_or_else(|| EngineError::Invalid("column.dtype is required".into()))?;
        let dt = dtype::parse(dtv)?;
        let s = match dt {
            DataType::Null => {
                if vs.iter().any(|value| !value.is_null()) {
                    return Err(EngineError::Invalid(
                        "Null column contains a non-null logical value".into(),
                    ));
                }
                Series::full_null(name, vs.len(), &DataType::Null)
            }
            DataType::Boolean => Series::new(
                name,
                vs.iter()
                    .map(|v| {
                        if v.is_null() {
                            Ok(None)
                        } else {
                            v.as_bool()
                                .or_else(|| v.get("value").and_then(Value::as_bool))
                                .map(Some)
                                .ok_or_else(|| EngineError::Invalid("invalid boolean".into()))
                        }
                    })
                    .collect::<Result<Vec<_>>>()?,
            ),
            DataType::String => Series::new(
                name,
                vs.iter()
                    .map(|v| {
                        if v.is_null() {
                            Ok(None)
                        } else {
                            v.as_str()
                                .or_else(|| v.get("value").and_then(Value::as_str))
                                .map(Some)
                                .ok_or_else(|| EngineError::Invalid("invalid string".into()))
                        }
                    })
                    .collect::<Result<Vec<_>>>()?,
            ),
            DataType::Binary | DataType::BinaryOffset => {
                let vals = vs
                    .iter()
                    .map(|v| {
                        if v.is_null() {
                            Ok(None)
                        } else {
                            let s = v
                                .as_str()
                                .or_else(|| v.get("base64").and_then(Value::as_str))
                                .ok_or_else(|| {
                                    EngineError::Invalid("binary requires base64".into())
                                })?;
                            base64::engine::general_purpose::STANDARD
                                .decode(s)
                                .map(Some)
                                .map_err(|_| EngineError::Invalid("invalid base64".into()))
                        }
                    })
                    .collect::<Result<Vec<_>>>()?;
                if dt == DataType::BinaryOffset {
                    let values = vals
                        .into_iter()
                        .map(|value| value.map_or(AnyValue::Null, AnyValue::BinaryOwned))
                        .collect::<Vec<_>>();
                    Series::from_any_values_and_dtype(name, &values, &dt, true).map_err(|e| {
                        EngineError::Invalid(format!(
                            "binary offset import cannot be represented: {e}"
                        ))
                    })?
                } else {
                    Series::new(name, vals)
                }
            }
            DataType::Float16 => Series::new(
                name,
                vs.iter()
                    .map(|v| {
                        if v.is_null() {
                            Ok(None)
                        } else {
                            float16(v).map(Some)
                        }
                    })
                    .collect::<Result<Vec<_>>>()?,
            ),
            DataType::Float32 => Series::new(
                name,
                vs.iter()
                    .map(|v| {
                        if v.is_null() {
                            Ok(None)
                        } else {
                            float(v, 32).map(|n| Some(n as f32))
                        }
                    })
                    .collect::<Result<Vec<_>>>()?,
            ),
            DataType::Float64 => Series::new(
                name,
                vs.iter()
                    .map(|v| {
                        if v.is_null() {
                            Ok(None)
                        } else {
                            float(v, 64).map(Some)
                        }
                    })
                    .collect::<Result<Vec<_>>>()?,
            ),
            DataType::UInt8
            | DataType::UInt16
            | DataType::UInt32
            | DataType::UInt64
            | DataType::UInt128 => {
                let vals = vs
                    .iter()
                    .map(|v| {
                        if v.is_null() {
                            Ok(None)
                        } else {
                            uint(v).map(Some)
                        }
                    })
                    .collect::<Result<Vec<_>>>()?;
                Series::new(name, vals).strict_cast(&dt).map_err(|e| {
                    EngineError::Invalid(format!("unsigned integer import is out of range: {e}"))
                })?
            }
            DataType::Decimal(precision, scale) => {
                let vals = vs
                    .iter()
                    .map(|v| {
                        if v.is_null() {
                            Ok(None)
                        } else {
                            int(v).map(Some)
                        }
                    })
                    .collect::<Result<Vec<_>>>()?;
                Series::new(name, vals)
                    .into_decimal(precision, scale)
                    .map_err(|e| EngineError::Invalid(format!("decimal import is invalid: {e}")))?
            }
            _ if dt.is_integer()
                || matches!(
                    dt,
                    DataType::Date
                        | DataType::Datetime(_, _)
                        | DataType::Duration(_)
                        | DataType::Time
                ) =>
            {
                if matches!(dt, DataType::Time) {
                    const NANOS_PER_DAY: i128 = 86_400_000_000_000;
                    for value in vs.iter().filter(|value| !value.is_null()) {
                        let value = int(value)?;
                        if !(0..NANOS_PER_DAY).contains(&value) {
                            return Err(EngineError::Invalid(
                                "time value must be in 0..86400000000000 nanoseconds".into(),
                            ));
                        }
                    }
                }
                let vals = vs
                    .iter()
                    .map(|v| {
                        if v.is_null() {
                            Ok(None)
                        } else {
                            int(v).map(Some)
                        }
                    })
                    .collect::<Result<Vec<_>>>()?;
                Series::new(name, vals).strict_cast(&dt).map_err(|e| {
                    EngineError::Invalid(format!("integer or temporal import is out of range: {e}"))
                })?
            }
            _ => return Err(EngineError::Unsupported(format!("batch import for {dt:?}"))),
        };
        out.push(s.into_column());
    }
    DataFrame::new(height.unwrap_or(0), out)
        .map_err(|e| EngineError::Invalid(format!("invalid record batch: {e}")))
}

pub fn info(df: &DataFrame) -> Value {
    json!({"width":df.width(), "height":df.height(), "schema":df.columns().iter().map(|c|json!({"name":c.name().as_str(),"dtype":dtype::descriptor(c.dtype())})).collect::<Vec<_>>()})
}

pub fn export(df: &DataFrame) -> Result<Value> {
    let mut columns = Vec::with_capacity(df.width());
    for c in df.columns() {
        let s = c.as_materialized_series();
        // Materialize the bitmap once. Calling `Series::is_null` per row rebuilt
        // an O(rows) mask for every element.
        let nulls = s.is_null();
        let vals = (0..s.len())
            .map(|i| {
                if nulls.get(i).unwrap_or(false) {
                    return Ok(Value::Null);
                }
                let av = s.get(i)?;
                Ok(match av {
                    AnyValue::Boolean(v) => json!(v),
                    AnyValue::String(v) => json!(v),
                    AnyValue::StringOwned(v) => json!(v.as_str()),
                    AnyValue::UInt8(v) => json!(v),
                    AnyValue::UInt16(v) => json!(v),
                    AnyValue::UInt32(v) => json!(v),
                    AnyValue::UInt64(v) => json!(v.to_string()),
                    AnyValue::UInt128(v) => json!(v.to_string()),
                    AnyValue::Int8(v) => json!(v),
                    AnyValue::Int16(v) => json!(v),
                    AnyValue::Int32(v) => json!(v),
                    AnyValue::Int64(v) => json!(v.to_string()),
                    AnyValue::Int128(v) => json!(v.to_string()),
                    AnyValue::Float16(v) => json!({"floatBits":format!("{:04x}",v.to_bits())}),
                    AnyValue::Float32(v) => json!({"floatBits":format!("{:08x}",v.to_bits())}),
                    AnyValue::Float64(v) => json!({"floatBits":format!("{:016x}",v.to_bits())}),
                    AnyValue::Binary(v) => {
                        json!({"base64":base64::engine::general_purpose::STANDARD.encode(v)})
                    }
                    AnyValue::Date(v) => json!({"value":v.to_string()}),
                    AnyValue::Datetime(v, _, _) | AnyValue::Duration(v, _) | AnyValue::Time(v) => {
                        json!({"value":v.to_string()})
                    }
                    AnyValue::Decimal(v, _, _) => json!({"unscaled":v.to_string()}),
                    x => return Err(EngineError::Unsupported(format!("export value {x:?}"))),
                })
            })
            .collect::<Result<Vec<_>>>()?;
        columns.push(
            json!({"name":c.name().as_str(),"dtype":dtype::descriptor(c.dtype()),"values":vals}),
        );
    }
    Ok(json!({"length":df.height(), "columns":columns}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn copied_scalar_matrix_round_trips_boundaries_bits_and_nulls() {
        let specifications = [
            (json!({"kind":"null"}), Value::Null),
            (json!({"kind":"boolean"}), json!(true)),
            (json!({"kind":"uint8"}), json!(u8::MAX)),
            (json!({"kind":"uint16"}), json!(u16::MAX)),
            (json!({"kind":"uint32"}), json!(u32::MAX)),
            (json!({"kind":"uint64"}), json!(u64::MAX.to_string())),
            (json!({"kind":"uint128"}), json!(u128::MAX.to_string())),
            (json!({"kind":"int8"}), json!(i8::MIN)),
            (json!({"kind":"int16"}), json!(i16::MIN)),
            (json!({"kind":"int32"}), json!(i32::MIN)),
            (json!({"kind":"int64"}), json!(i64::MIN.to_string())),
            (json!({"kind":"int128"}), json!(i128::MIN.to_string())),
            (json!({"kind":"float16"}), json!({"floatBits":"8000"})),
            (json!({"kind":"float32"}), json!({"floatBits":"7fc00001"})),
            (
                json!({"kind":"float64"}),
                json!({"floatBits":"7ff8000000000001"}),
            ),
            (
                json!({"kind":"decimal","precision":38,"scale":2}),
                json!({"unscaled":"99999999999999999999999999999999999999"}),
            ),
            (json!({"kind":"string"}), json!("boundary")),
            (json!({"kind":"binary"}), json!({"base64":"AP8="})),
            (json!({"kind":"binaryOffset"}), json!({"base64":"AQI="})),
            (
                json!({"kind":"date"}),
                json!({"value":i32::MIN.to_string()}),
            ),
            (
                json!({"kind":"datetime","unit":"nanoseconds"}),
                json!({"value":i64::MIN.to_string()}),
            ),
            (
                json!({"kind":"duration","unit":"milliseconds"}),
                json!({"value":i64::MAX.to_string()}),
            ),
            (json!({"kind":"time"}), json!({"value":"86399999999999"})),
        ];
        let columns = specifications
            .iter()
            .enumerate()
            .map(|(index, (dtype, value))| {
                json!({"name":format!("c{index}"),"dtype":dtype,"values":[value,null]})
            })
            .collect::<Vec<_>>();
        let output = export(&import(&json!({"length":2,"columns":columns})).unwrap()).unwrap();
        let exported = output["columns"].as_array().unwrap();
        assert_eq!(exported.len(), 23);
        for (index, (dtype, _)) in specifications.iter().enumerate() {
            assert_eq!(&exported[index]["dtype"], dtype);
            assert!(exported[index]["values"][1].is_null());
        }
        assert_eq!(exported[11]["values"][0], json!(i128::MIN.to_string()));
        assert_eq!(exported[12]["values"][0], json!({"floatBits":"8000"}));
        assert_eq!(
            exported[14]["values"][0],
            json!({"floatBits":"7ff8000000000001"})
        );
        assert_eq!(
            exported[15]["values"][0],
            json!({"unscaled":"99999999999999999999999999999999999999"})
        );
    }

    #[test]
    fn null_dtype_accepts_only_logically_null_values() {
        assert!(import(&json!({"columns":[{
            "name":"n","dtype":{"kind":"null"},"values":[1],"validity":[true]
        }]}))
        .is_err());
        assert!(import(&json!({"columns":[{
            "name":"n","dtype":{"kind":"null"},"values":[1],"validity":[false]
        }]}))
        .is_ok());
    }
}
