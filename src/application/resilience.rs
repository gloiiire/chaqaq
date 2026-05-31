use crate::application::error::PinkhaError;
use std::time::Duration;

/// Nombre maximal de tentatives (1 essai initial + 2 retries).
pub const MAX_ATTEMPTS: u32 = 3;

/// Délai initial avant le premier retry (doublé à chaque tentative, plafonné).
pub const INITIAL_DELAY_MS: u64 = 50;

/// Plafond du backoff exponentiel.
pub const MAX_DELAY_MS: u64 = 500;

/// Exécute `op` avec retry exponentiel sur les erreurs transitoires.
/// Les erreurs métier (NotFound, InvalidOperation) ne sont **jamais** retentées.
pub fn retry_with_backoff<T, F>(mut op: F) -> Result<T, PinkhaError>
where
    F: FnMut() -> Result<T, PinkhaError>,
{
    let mut attempts: u32 = 0;
    let mut delay_ms: u64 = INITIAL_DELAY_MS;
    loop {
        match op() {
            Ok(value) => return Ok(value),
            Err(err) if attempts + 1 < MAX_ATTEMPTS && is_transient(&err) => {
                std::thread::sleep(Duration::from_millis(delay_ms));
                attempts += 1;
                delay_ms = (delay_ms * 2).min(MAX_DELAY_MS);
            }
            Err(err) => return Err(err),
        }
    }
}

/// Identifie les erreurs qui méritent un retry : verrous SQLite, I/O bloquante,
/// jamais les erreurs métier (NotFound, InvalidOperation).
pub fn is_transient(err: &PinkhaError) -> bool {
    match err {
        PinkhaError::Db(msg) => {
            let lower = msg.to_lowercase();
            lower.contains("busy") || lower.contains("locked") || lower.contains("database is locked")
        }
        PinkhaError::Io(io_err) => matches!(
            io_err.kind(),
            std::io::ErrorKind::WouldBlock
                | std::io::ErrorKind::Interrupted
                | std::io::ErrorKind::TimedOut
        ),
        PinkhaError::NotFound(_) | PinkhaError::InvalidOperation(_) | PinkhaError::Json(_) => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;
    use uuid::Uuid;

    #[test]
    fn retourne_la_valeur_au_premier_essai_reussi() {
        let appels = Cell::new(0u32);
        let result = retry_with_backoff(|| {
            appels.set(appels.get() + 1);
            Ok::<_, PinkhaError>(42)
        });
        assert_eq!(result.unwrap(), 42);
        assert_eq!(appels.get(), 1);
    }

    #[test]
    fn retry_sur_erreur_db_locked_puis_reussit() {
        let appels = Cell::new(0u32);
        let result = retry_with_backoff(|| {
            appels.set(appels.get() + 1);
            if appels.get() < 2 {
                Err(PinkhaError::Db("database is locked".into()))
            } else {
                Ok(7)
            }
        });
        assert_eq!(result.unwrap(), 7);
        assert_eq!(appels.get(), 2);
    }

    #[test]
    fn ne_retry_pas_sur_not_found() {
        let appels = Cell::new(0u32);
        let id = Uuid::new_v4();
        let result: Result<i32, _> = retry_with_backoff(|| {
            appels.set(appels.get() + 1);
            Err(PinkhaError::NotFound(id))
        });
        assert!(matches!(result, Err(PinkhaError::NotFound(_))));
        assert_eq!(appels.get(), 1);
    }

    #[test]
    fn ne_retry_pas_sur_invalid_operation() {
        let appels = Cell::new(0u32);
        let result: Result<i32, _> = retry_with_backoff(|| {
            appels.set(appels.get() + 1);
            Err(PinkhaError::InvalidOperation("bad".into()))
        });
        assert!(matches!(result, Err(PinkhaError::InvalidOperation(_))));
        assert_eq!(appels.get(), 1);
    }

    #[test]
    fn abandonne_apres_max_attempts() {
        let appels = Cell::new(0u32);
        let result: Result<i32, _> = retry_with_backoff(|| {
            appels.set(appels.get() + 1);
            Err(PinkhaError::Db("busy".into()))
        });
        assert!(result.is_err());
        assert_eq!(appels.get(), MAX_ATTEMPTS);
    }

    #[test]
    fn is_transient_couvre_les_cas_attendus() {
        assert!(is_transient(&PinkhaError::Db("database is locked".into())));
        assert!(is_transient(&PinkhaError::Db("BUSY (5)".into())));
        assert!(is_transient(&PinkhaError::Io(std::io::Error::from(std::io::ErrorKind::WouldBlock))));
        assert!(!is_transient(&PinkhaError::NotFound(Uuid::new_v4())));
        assert!(!is_transient(&PinkhaError::InvalidOperation("x".into())));
    }
}
