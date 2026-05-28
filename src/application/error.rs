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

#[cfg(test)]
mod tests {
    use super::*;
    use std::error::Error;
    use std::io;

    #[test]
    fn test_display_non_trouve() {
        let id = Uuid::new_v4();
        let msg = ChaqaqError::NonTrouve(id).to_string();
        assert!(msg.contains("introuvable"));
        assert!(msg.contains(&id.to_string()));
    }

    #[test]
    fn test_display_io() {
        let err = ChaqaqError::Io(io::Error::new(io::ErrorKind::PermissionDenied, "refusé"));
        assert!(err.to_string().contains("I/O"));
    }

    #[test]
    fn test_display_json() {
        let json_err = serde_json::from_str::<serde_json::Value>("invalide").unwrap_err();
        let err = ChaqaqError::Json(json_err);
        assert!(err.to_string().contains("JSON"));
    }

    #[test]
    fn test_from_io() {
        let err: ChaqaqError = io::Error::new(io::ErrorKind::Other, "test").into();
        assert!(matches!(err, ChaqaqError::Io(_)));
    }

    #[test]
    fn test_from_json() {
        let json_err = serde_json::from_str::<serde_json::Value>("invalide").unwrap_err();
        let err: ChaqaqError = json_err.into();
        assert!(matches!(err, ChaqaqError::Json(_)));
    }

    #[test]
    fn test_source_io_est_some() {
        let err = ChaqaqError::Io(io::Error::new(io::ErrorKind::Other, "test"));
        assert!(err.source().is_some());
    }

    #[test]
    fn test_source_non_trouve_est_none() {
        let err = ChaqaqError::NonTrouve(Uuid::new_v4());
        assert!(err.source().is_none());
    }
}
