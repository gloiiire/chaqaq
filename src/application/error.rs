use std::fmt;
use uuid::Uuid;

#[derive(Debug)]
pub enum ChaqaqError {
    NotFound(Uuid),
    InvalidOperation(String),
    Io(std::io::Error),
    Json(serde_json::Error),
    /// Erreur base de données — message converti pour ne pas coupler
    /// l'application à une implémentation de stockage spécifique.
    Db(String),
}

impl fmt::Display for ChaqaqError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ChaqaqError::NotFound(id) => write!(f, "ressource introuvable : {id}"),
            ChaqaqError::InvalidOperation(msg) => write!(f, "opération invalide : {msg}"),
            ChaqaqError::Io(e) => write!(f, "erreur I/O : {e}"),
            ChaqaqError::Json(e) => write!(f, "erreur JSON : {e}"),
            ChaqaqError::Db(msg) => write!(f, "erreur base de données : {msg}"),
        }
    }
}

impl std::error::Error for ChaqaqError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            ChaqaqError::Io(e) => Some(e),
            ChaqaqError::Json(e) => Some(e),
            ChaqaqError::NotFound(_) => None,
            ChaqaqError::InvalidOperation(_) => None,
            ChaqaqError::Db(_) => None,
        }
    }
}

impl From<std::io::Error> for ChaqaqError {
    fn from(e: std::io::Error) -> Self {
        Self::Io(e)
    }
}

impl From<serde_json::Error> for ChaqaqError {
    fn from(e: serde_json::Error) -> Self {
        Self::Json(e)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::error::Error;
    use std::io;

    #[test]
    fn test_display_non_trouve() {
        let id = Uuid::new_v4();
        let msg = ChaqaqError::NotFound(id).to_string();
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
        let err = ChaqaqError::NotFound(Uuid::new_v4());
        assert!(err.source().is_none());
    }

    #[test]
    fn test_display_operation_invalide() {
        let err = ChaqaqError::InvalidOperation("bloc non textuel".to_string());
        assert!(err.to_string().contains("invalide"));
        assert!(err.to_string().contains("bloc non textuel"));
    }

    #[test]
    fn test_source_operation_invalide_est_none() {
        let err = ChaqaqError::InvalidOperation("x".to_string());
        assert!(err.source().is_none());
    }
}
