// Integration test: SQLite retry absorbs concurrent contention in a realistic
// scenario (multiple threads, simultaneous writes).

use pinkha::application::error::PinkhaError;
use pinkha::application::repository::DocumentRepository;
use pinkha::application::resilience::{is_transient, retry_with_backoff};
use pinkha::domain::document::Document;
use pinkha::domain::parser::parse_inline;
use pinkha::infrastructure::sqlite_document_store::SqliteDocumentStore;
use std::sync::Arc;
use std::thread;
use uuid::Uuid;

fn db_path() -> String {
    std::env::temp_dir()
        .join(format!("pinkha_retry_{}.db", Uuid::new_v4()))
        .to_string_lossy()
        .into_owned()
}

#[test]
fn ecritures_concurrentes_multi_threads_aboutissent_toutes() {
    let path = db_path();
    let store = Arc::new(SqliteDocumentStore::new(&path).unwrap());

    let mut handles = vec![];
    for i in 0..30 {
        let store = Arc::clone(&store);
        handles.push(thread::spawn(move || {
            let doc = Document::new(parse_inline(&format!("Doc {i}")));
            store.save(&doc).expect("retry doit absorber les conflits")
        }));
    }

    for h in handles {
        h.join().unwrap();
    }

    let metas = store.list().unwrap();
    assert_eq!(
        metas.len(),
        30,
        "les 30 écritures concurrentes doivent persister"
    );

    let _ = std::fs::remove_file(&path);
    let _ = std::fs::remove_file(format!("{path}-wal"));
    let _ = std::fs::remove_file(format!("{path}-shm"));
}

#[test]
fn lectures_et_ecritures_concurrentes_coexistent() {
    let path = db_path();
    let store = Arc::new(SqliteDocumentStore::new(&path).unwrap());

    // Seed
    for i in 0..5 {
        let doc = Document::new(parse_inline(&format!("Pre {i}")));
        store.save(&doc).unwrap();
    }

    let mut handles = vec![];
    for i in 0..20 {
        let store = Arc::clone(&store);
        let h = if i % 2 == 0 {
            thread::spawn(move || {
                store
                    .save(&Document::new(parse_inline(&format!("W {i}"))))
                    .expect("save doit réussir");
            })
        } else {
            thread::spawn(move || {
                let _ = store.list().expect("list doit réussir");
            })
        };
        handles.push(h);
    }
    for h in handles {
        h.join().unwrap();
    }

    // 5 pre-seeded + 10 writes (even i over 20)
    assert_eq!(store.list().unwrap().len(), 15);

    let _ = std::fs::remove_file(&path);
    let _ = std::fs::remove_file(format!("{path}-wal"));
    let _ = std::fs::remove_file(format!("{path}-shm"));
}

#[test]
fn retry_n_intervient_pas_sur_not_found() {
    let path = db_path();
    let store = SqliteDocumentStore::new(&path).unwrap();

    // No retry expected on NotFound — the error propagates immediately.
    let inconnu = Uuid::new_v4();
    let result = store.load(inconnu);
    assert!(matches!(result, Err(PinkhaError::NotFound(_))));

    // Confirm via is_transient that NotFound is never considered transient.
    if let Err(e) = store.load(inconnu) {
        assert!(
            !is_transient(&e),
            "NotFound ne doit jamais être transitoire"
        );
    }

    let _ = std::fs::remove_file(&path);
}

#[test]
fn retry_helper_remonte_apres_max_tentatives_sur_erreur_persistante() {
    let mut appels = 0u32;
    let result: Result<i32, PinkhaError> = retry_with_backoff(|| {
        appels += 1;
        Err(PinkhaError::Db("database is locked".to_string()))
    });

    assert!(matches!(result, Err(PinkhaError::Db(_))));
    assert_eq!(appels, 3, "exactly MAX_ATTEMPTS=3 essais avant de renoncer");
}
