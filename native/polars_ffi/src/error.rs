use serde_json::{json, Value};

#[derive(Debug, thiserror::Error)]
pub enum EngineError {
    #[error("{0}")]
    Invalid(String),
    #[error("{0}")]
    Protocol(String),
    #[error("{0}")]
    Handle(String),
    #[error("{0}")]
    Unsupported(String),
    #[error("{0}")]
    Execution(String),
    #[error("{0}")]
    Io(String),
    #[error("{0}")]
    Cancelled(String),
    #[error("{0}")]
    Internal(String),
}

pub type Result<T> = std::result::Result<T, EngineError>;

impl EngineError {
    pub fn category(&self) -> &'static str {
        match self {
            Self::Invalid(_) => "invalidRequest",
            Self::Protocol(_) => "protocolError",
            Self::Handle(_) => "invalidHandle",
            Self::Unsupported(_) => "unsupported",
            Self::Execution(_) => "compute",
            Self::Io(_) => "io",
            Self::Cancelled(_) => "cancelled",
            Self::Internal(_) => "internalError",
        }
    }

    pub fn envelope(&self) -> Value {
        json!({"ok": false, "error": {
            "category": self.category(), "message": self.to_string()
        }})
    }
}

impl From<polars::error::PolarsError> for EngineError {
    fn from(value: polars::error::PolarsError) -> Self {
        fn is_io(error: &polars::error::PolarsError) -> bool {
            match error {
                polars::error::PolarsError::IO { .. } => true,
                polars::error::PolarsError::Context { error, .. }
                | polars::error::PolarsError::ExprContext { error, .. } => is_io(error),
                _ => false,
            }
        }
        let message = value.to_string();
        if is_io(&value) {
            Self::Io(message)
        } else {
            Self::Execution(message)
        }
    }
}

impl From<std::io::Error> for EngineError {
    fn from(value: std::io::Error) -> Self {
        Self::Io(value.to_string())
    }
}
