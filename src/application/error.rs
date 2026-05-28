use std::fmt;
use uuid::Uuid;

#[derive(Debug)]
pub enum ChaqaqError {
    NonTrouve(Uuid),
    Io(std::io::Error),
    Json(serde_json::Error),
}

impl fmt::Display for ChaqaqError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ChaqaqError::NonTrouve(id) => write!(f, "document introuvable : {id}"),
            ChaqaqError::Io(e)         => write!(f, "erreur I/O : {e}"),
            ChaqaqError::Json(e)       => write!(f, "erreur JSON : {e}"),
        }
    }
}

impl std::error::Error for ChaqaqError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            ChaqaqError::Io(e)   => Some(e),
            ChaqaqError::Json(e) => Some(e),
            ChaqaqError::NonTrouve(_) => None,
        }
    }
}

impl From<std::io::Error> for ChaqaqError {
    fn from(e: std::io::Error) -> Self { Self::Io(e) }
}

impl From<serde_json::Error> for ChaqaqError {
    fn from(e: serde_json::Error) -> Self { Self::Json(e) }
}
