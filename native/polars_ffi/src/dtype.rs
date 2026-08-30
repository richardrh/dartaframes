use crate::error::{EngineError, Result};
use polars::datatypes::extension::get_extension_type_or_generic;
use polars::prelude::*;
use serde_json::{json, Value};

fn kind(v: &Value) -> Result<&str> {
    v.get("kind")
        .and_then(Value::as_str)
        .ok_or_else(|| EngineError::Invalid("dtype.kind must be a string".into()))
}

fn unit(v: &Value) -> Result<TimeUnit> {
    match v
        .get("unit")
        .and_then(Value::as_str)
        .unwrap_or("microseconds")
    {
        "nanoseconds" | "ns" => Ok(TimeUnit::Nanoseconds),
        "microseconds" | "us" => Ok(TimeUnit::Microseconds),
        "milliseconds" | "ms" => Ok(TimeUnit::Milliseconds),
        x => Err(EngineError::Invalid(format!("unknown time unit '{x}'"))),
    }
}

/// Parse descriptors that can safely be materialized by this engine. Every
/// protocol kind is recognized; retention-only kinds fail explicitly.
pub fn parse(v: &Value) -> Result<DataType> {
    let dtype_kind = kind(v)?;
    let parameters: &[&str] = match dtype_kind {
        "datetime" => &["unit", "timeZone"],
        "duration" => &["unit"],
        "decimal" => &["precision", "scale"],
        "list" => &["inner"],
        "array" => &["inner", "width"],
        "struct" => &["fields"],
        "enum" => &["categories"],
        "extension" => &["name", "storage", "metadata"],
        "categorical" => &["name", "namespace", "hash", "physical"],
        "object" => &["label"],
        "unknown" => &["unknownKind", "value"],
        _ => &[],
    };
    let object = v
        .as_object()
        .ok_or_else(|| EngineError::Invalid("dtype must be an object".into()))?;
    for key in object.keys() {
        if key != "kind" && !parameters.contains(&key.as_str()) {
            return Err(EngineError::Invalid(format!(
                "unknown or irrelevant dtype field '{key}'"
            )));
        }
    }
    Ok(match dtype_kind {
        "null" => DataType::Null,
        "boolean" | "bool" => DataType::Boolean,
        "uint8" => DataType::UInt8,
        "uint16" => DataType::UInt16,
        "uint32" => DataType::UInt32,
        "uint64" => DataType::UInt64,
        "uint128" => DataType::UInt128,
        "int8" => DataType::Int8,
        "int16" => DataType::Int16,
        "int32" => DataType::Int32,
        "int64" => DataType::Int64,
        "int128" => DataType::Int128,
        "float16" => DataType::Float16,
        "float32" => DataType::Float32,
        "float64" => DataType::Float64,
        "string" => DataType::String,
        "binary" => DataType::Binary,
        "binaryOffset" => DataType::BinaryOffset,
        "date" => DataType::Date,
        "datetime" => DataType::Datetime(
            unit(v)?,
            TimeZone::opt_try_new(v.get("timeZone").and_then(Value::as_str))
                .map_err(|e| EngineError::Invalid(format!("invalid time zone: {e}")))?,
        ),
        "duration" => DataType::Duration(unit(v)?),
        "time" => DataType::Time,
        "decimal" => {
            let precision = v
                .get("precision")
                .and_then(Value::as_u64)
                .ok_or_else(|| EngineError::Invalid("decimal.precision is required".into()))?;
            let scale = v
                .get("scale")
                .and_then(Value::as_i64)
                .ok_or_else(|| EngineError::Invalid("decimal.scale is required".into()))?;
            if !(1..=38).contains(&precision) || scale < 0 || scale as u64 > precision {
                return Err(EngineError::Invalid(
                    "decimal precision must be 1..38 and scale must be 0..precision".into(),
                ));
            }
            DataType::Decimal(precision as usize, scale as usize)
        }
        "list" => {
            DataType::List(Box::new(parse(v.get("inner").ok_or_else(|| {
                EngineError::Invalid("list.inner is required".into())
            })?)?))
        }
        "array" => {
            let width = v
                .get("width")
                .and_then(Value::as_u64)
                .ok_or_else(|| EngineError::Invalid("array.width is required".into()))?;
            let width = usize::try_from(width).map_err(|_| {
                EngineError::Invalid("array.width does not fit this platform".into())
            })?;
            if width == 0 {
                return Err(EngineError::Invalid("array.width must be positive".into()));
            }
            DataType::Array(
                Box::new(parse(v.get("inner").ok_or_else(|| {
                    EngineError::Invalid("array.inner is required".into())
                })?)?),
                width,
            )
        }
        "struct" => {
            let fields = v
                .get("fields")
                .and_then(Value::as_array)
                .ok_or_else(|| EngineError::Invalid("struct.fields must be an array".into()))?;
            DataType::Struct(
                fields
                    .iter()
                    .map(|field| {
                        let object = field.as_object().ok_or_else(|| {
                            EngineError::Invalid("struct field must be an object".into())
                        })?;
                        if object.keys().any(|key| key != "name" && key != "dtype") {
                            return Err(EngineError::Invalid(
                                "unknown or irrelevant struct field property".into(),
                            ));
                        }
                        let name = field.get("name").and_then(Value::as_str).ok_or_else(|| {
                            EngineError::Invalid("struct field.name must be a string".into())
                        })?;
                        let dtype = field.get("dtype").ok_or_else(|| {
                            EngineError::Invalid("struct field.dtype is required".into())
                        })?;
                        Ok(Field::new(name.into(), parse(dtype)?))
                    })
                    .collect::<Result<Vec<_>>>()?,
            )
        }
        "categorical" => {
            return Err(EngineError::Unsupported(
                "categorical namespace identity cannot reconstruct Polars Categories mapping"
                    .into(),
            ))
        }
        "enum" => {
            let values = v
                .get("categories")
                .and_then(Value::as_array)
                .ok_or_else(|| EngineError::Invalid("enum.categories must be an array".into()))?;
            let values = values
                .iter()
                .map(|value| {
                    value.as_str().ok_or_else(|| {
                        EngineError::Invalid("enum categories must be strings".into())
                    })
                })
                .collect::<Result<Vec<_>>>()?;
            let categories = FrozenCategories::new(values)
                .map_err(|e| EngineError::Invalid(format!("invalid enum categories: {e}")))?;
            let mapping = categories.mapping().clone();
            DataType::Enum(categories, mapping)
        }
        "extension" => {
            let name = required_string(v, "name", "extension")?;
            let storage =
                parse(v.get("storage").ok_or_else(|| {
                    EngineError::Invalid("extension.storage is required".into())
                })?)?;
            let metadata = match v.get("metadata") {
                None => None,
                Some(value) => Some(value.as_str().ok_or_else(|| {
                    EngineError::Invalid("extension.metadata must be a string".into())
                })?),
            };
            let extension = get_extension_type_or_generic(name, &storage, metadata);
            DataType::Extension(extension, Box::new(storage))
        }
        "object" => {
            return Err(EngineError::Unsupported(
                "Object is native-retention only".into(),
            ))
        }
        "unknown" => {
            return Err(EngineError::Unsupported(
                "Unknown is inference-only and cannot be materialized".into(),
            ))
        }
        x => return Err(EngineError::Invalid(format!("unknown dtype kind '{x}'"))),
    })
}

fn required_string<'a>(v: &'a Value, key: &str, owner: &str) -> Result<&'a str> {
    v.get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| EngineError::Invalid(format!("{owner}.{key} must be a string")))
}

pub fn descriptor(dt: &DataType) -> Value {
    let plain = |kind: &str| json!({"kind": kind});
    match dt {
        DataType::Null => plain("null"),
        DataType::Boolean => plain("boolean"),
        DataType::UInt8 => plain("uint8"),
        DataType::UInt16 => plain("uint16"),
        DataType::UInt32 => plain("uint32"),
        DataType::UInt64 => plain("uint64"),
        DataType::UInt128 => plain("uint128"),
        DataType::Int8 => plain("int8"),
        DataType::Int16 => plain("int16"),
        DataType::Int32 => plain("int32"),
        DataType::Int64 => plain("int64"),
        DataType::Int128 => plain("int128"),
        DataType::Float16 => plain("float16"),
        DataType::Float32 => plain("float32"),
        DataType::Float64 => plain("float64"),
        DataType::String => plain("string"),
        DataType::Binary => plain("binary"),
        DataType::BinaryOffset => plain("binaryOffset"),
        DataType::Date => plain("date"),
        DataType::Time => plain("time"),
        DataType::Datetime(u, z) => {
            let mut value = json!({"kind":"datetime", "unit": unit_name(*u)});
            if let Some(time_zone) = z {
                value["timeZone"] = json!(time_zone.as_str());
            }
            value
        }
        DataType::Duration(u) => json!({"kind":"duration", "unit": unit_name(*u)}),
        DataType::Decimal(p, s) => json!({"kind":"decimal", "precision":p, "scale":s}),
        DataType::List(i) => json!({"kind":"list", "inner":descriptor(i)}),
        DataType::Array(i, n) => json!({"kind":"array", "inner":descriptor(i), "width":n}),
        DataType::Struct(fields) => {
            json!({"kind":"struct", "fields":fields.iter().map(|f| json!({"name":f.name().as_str(), "dtype":descriptor(f.dtype())})).collect::<Vec<_>>() })
        }
        DataType::Categorical(categories, _) => json!({
            "kind":"categorical",
            "name":categories.name().as_str(),
            "namespace":categories.namespace().as_str(),
            "hash":categories.hash().to_string(),
            "physical":categorical_physical_name(categories.physical())
        }),
        DataType::Enum(categories, _) => json!({
            "kind":"enum",
            "categories":categories.categories().values_iter().collect::<Vec<_>>()
        }),
        DataType::Object(label) => json!({"kind":"object", "label":label}),
        DataType::Extension(extension, storage) => {
            let mut value = json!({
                "kind":"extension",
                "name":extension.name(),
                "storage":descriptor(storage)
            });
            if let Some(metadata) = extension.serialize_metadata() {
                value["metadata"] = json!(metadata);
            }
            value
        }
        DataType::Unknown(unknown) => match unknown {
            UnknownKind::Any => json!({"kind":"unknown", "unknownKind":"any"}),
            UnknownKind::Float => json!({"kind":"unknown", "unknownKind":"float"}),
            UnknownKind::Str => json!({"kind":"unknown", "unknownKind":"string"}),
            UnknownKind::Int(value) => json!({
                "kind":"unknown", "unknownKind":"integer", "value":value.to_string()
            }),
        },
    }
}

fn categorical_physical_name(physical: CategoricalPhysical) -> &'static str {
    match physical {
        CategoricalPhysical::U8 => "uint8",
        CategoricalPhysical::U16 => "uint16",
        CategoricalPhysical::U32 => "uint32",
    }
}

fn unit_name(u: TimeUnit) -> &'static str {
    match u {
        TimeUnit::Nanoseconds => "nanoseconds",
        TimeUnit::Microseconds => "microseconds",
        TimeUnit::Milliseconds => "milliseconds",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn descriptors_retain_all_native_parameters() {
        assert_eq!(
            descriptor(&DataType::Object("widget")),
            json!({"kind":"object", "label":"widget"})
        );
        for (kind, expected) in [
            (
                UnknownKind::Any,
                json!({"kind":"unknown","unknownKind":"any"}),
            ),
            (
                UnknownKind::Float,
                json!({"kind":"unknown","unknownKind":"float"}),
            ),
            (
                UnknownKind::Str,
                json!({"kind":"unknown","unknownKind":"string"}),
            ),
            (
                UnknownKind::Int(i128::MIN),
                json!({"kind":"unknown","unknownKind":"integer","value":i128::MIN.to_string()}),
            ),
        ] {
            assert_eq!(descriptor(&DataType::Unknown(kind)), expected);
        }

        let categories = Categories::new("products".into(), "42".into(), CategoricalPhysical::U16);
        let categorical = DataType::Categorical(categories.clone(), categories.mapping());
        assert_eq!(
            descriptor(&categorical),
            json!({
                "kind":"categorical", "name":"products", "namespace":"42", "hash":categories.hash().to_string(), "physical":"uint16"
            })
        );

        let frozen = FrozenCategories::new(["medium", "small", "large"]).unwrap();
        let enumeration = DataType::Enum(frozen.clone(), frozen.mapping().clone());
        assert_eq!(
            descriptor(&enumeration),
            json!({
                "kind":"enum", "categories":["medium", "small", "large"]
            })
        );

        let extension = parse(&json!({
            "kind":"extension", "name":"example.point", "storage":{"kind":"int64"},
            "metadata":"v1"
        }))
        .unwrap();
        let nested = DataType::Struct(vec![
            Field::new("id".into(), DataType::UInt32),
            Field::new("payload".into(), extension),
        ]);
        assert_eq!(
            descriptor(&nested),
            json!({"kind":"struct","fields":[
                {"name":"id","dtype":{"kind":"uint32"}},
                {"name":"payload","dtype":{"kind":"extension","name":"example.point","storage":{"kind":"int64"},"metadata":"v1"}}
            ]})
        );
    }

    #[test]
    fn parameterized_descriptors_parse_without_losing_identity() {
        for value in [
            json!({"kind":"struct","fields":[{"name":"x","dtype":{"kind":"list","inner":{"kind":"string"}}}]}),
            json!({"kind":"enum","categories":["z","a"]}),
            json!({"kind":"extension","name":"unknown.custom","storage":{"kind":"binary"}}),
        ] {
            assert_eq!(descriptor(&parse(&value).unwrap()), value);
        }
        assert!(matches!(
            parse(
                &json!({"kind":"categorical","name":"items","namespace":"custom","hash":"7","physical":"uint8"})
            ),
            Err(EngineError::Unsupported(_))
        ));
        assert!(parse(&json!({"kind":"enum","categories":["x","x"]})).is_err());
    }

    #[test]
    fn naive_datetime_omits_time_zone() {
        assert_eq!(
            descriptor(&DataType::Datetime(TimeUnit::Microseconds, None)),
            json!({"kind":"datetime", "unit":"microseconds"})
        );
    }
}
