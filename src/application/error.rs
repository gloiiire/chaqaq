use std::fmt;
use uuid::Uuid;

/// Application-level error type used across all layers of pinkha.
#[derive(Debug)]
pub enum PinkhaError {
    /// A resource with the given ID could not be found.
    NotFound(Uuid),
    /// The requested operation is semantically invalid (e.g. moving a block into itself).
    InvalidOperation(String),
    /// An underlying I/O error.
    Io(std::io::Error),
    /// A JSON serialisation or deserialisation error.
    Json(serde_json::Error),
    /// A storage error — message is converted to a string so that the application layer
    /// does not depend on a specific storage implementation (e.g. rusqlite).
    Db(String),
}

impl fmt::Display for PinkhaError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PinkhaError::NotFound(id) => write!(f, "resource not found: {id}"),
            PinkhaError::InvalidOperation(msg) => write!(f, "invalid operation: {msg}"),
            PinkhaError::Io(e) => write!(f, "I/O error: {e}"),
            PinkhaError::Json(e) => write!(f, "JSON error: {e}"),
            PinkhaError::Db(msg) => write!(f, "database error: {msg}"),
        }
    }
}

impl std::error::Error for PinkhaError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            PinkhaError::Io(e) => Some(e),
            PinkhaError::Json(e) => Some(e),
            PinkhaError::NotFound(_) => None,
            PinkhaError::InvalidOperation(_) => None,
            PinkhaError::Db(_) => None,
        }
    }
}

impl From<std::io::Error> for PinkhaError {
    fn from(e: std::io::Error) -> Self {
        Self::Io(e)
    }
}

impl From<serde_json::Error> for PinkhaError {
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
        let msg = PinkhaError::NotFound(id).to_string();
        assert!(msg.contains("not found"));
        assert!(msg.contains(&id.to_string()));
    }

    #[test]
    fn test_display_io() {
        let err = PinkhaError::Io(io::Error::new(io::ErrorKind::PermissionDenied, "refusé"));
        assert!(err.to_string().contains("I/O"));
    }

    #[test]
    fn test_display_json() {
        let json_err = serde_json::from_str::<serde_json::Value>("invalide").unwrap_err();
        let err = PinkhaError::Json(json_err);
        assert!(err.to_string().contains("JSON"));
    }

    #[test]
    fn test_from_io() {
        let err: PinkhaError = io::Error::new(io::ErrorKind::Other, "test").into();
        assert!(matches!(err, PinkhaError::Io(_)));
    }

    #[test]
    fn test_from_json() {
        let json_err = serde_json::from_str::<serde_json::Value>("invalide").unwrap_err();
        let err: PinkhaError = json_err.into();
        assert!(matches!(err, PinkhaError::Json(_)));
    }

    #[test]
    fn test_source_io_est_some() {
        let err = PinkhaError::Io(io::Error::new(io::ErrorKind::Other, "test"));
        assert!(err.source().is_some());
    }

    #[test]
    fn test_source_non_trouve_est_none() {
        let err = PinkhaError::NotFound(Uuid::new_v4());
        assert!(err.source().is_none());
    }

    #[test]
    fn test_display_operation_invalide() {
        let err = PinkhaError::InvalidOperation("bloc non textuel".to_string());
        assert!(err.to_string().contains("invalid"));
        assert!(err.to_string().contains("bloc non textuel"));
    }

    #[test]
    fn test_source_operation_invalide_est_none() {
        let err = PinkhaError::InvalidOperation("x".to_string());
        assert!(err.source().is_none());
    }
}
