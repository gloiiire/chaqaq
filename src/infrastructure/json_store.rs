use crate::application::error::PinkhaError;
use crate::application::repository::LeafRepository;
use crate::domain::leaf::{Leaf, LeafMeta};
use std::path::PathBuf;
use uuid::Uuid;

/// File-system leaf store that persists each leaf as a pretty-printed
/// JSON file named `<uuid>.json` inside a directory.
///
/// Kept alongside the SQLite store for tests and prototyping. Production code
/// should prefer [`SqliteLeafStore`].
pub struct JsonStore {
    dir: PathBuf,
}

impl JsonStore {
    /// Creates a new store rooted at `dir`. The directory is created on the
    /// first [`save`] call if it does not exist yet.
    pub fn new(dir: PathBuf) -> Self {
        Self { dir }
    }
}

impl LeafRepository for JsonStore {
    fn save(&self, doc: &Leaf) -> Result<(), PinkhaError> {
        std::fs::create_dir_all(&self.dir)?;
        let path = self.dir.join(format!("{}.json", doc.id));
        // Atomic write: write to a .tmp file then rename — the final file
        // remains the previous version if the process dies mid-write.
        let tmp = self.dir.join(format!(".{}.json.tmp", doc.id));
        std::fs::write(&tmp, serde_json::to_string_pretty(doc)?)?;
        std::fs::rename(&tmp, &path)?;
        Ok(())
    }

    fn load(&self, id: Uuid) -> Result<Leaf, PinkhaError> {
        let path = self.dir.join(format!("{}.json", id));
        let json = std::fs::read_to_string(&path).map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                PinkhaError::NotFound(id)
            } else {
                PinkhaError::Io(e)
            }
        })?;
        Ok(serde_json::from_str(&json)?)
    }

    fn list(&self) -> Result<Vec<LeafMeta>, PinkhaError> {
        // Filter on the `.json` extension (in-progress `.tmp` writes are ignored),
        // and silently skip corrupted files so a single bad file does not break
        // the entire listing.
        let mut metas = Vec::new();
        for entry in std::fs::read_dir(&self.dir)? {
            let path = entry?.path();
            if path.extension().and_then(|e| e.to_str()) != Some("json") {
                continue;
            }
            if let Ok(json) = std::fs::read_to_string(&path)
                && let Ok(meta) = serde_json::from_str::<LeafMeta>(&json)
            {
                metas.push(meta);
            }
        }
        Ok(metas)
    }

    fn delete(&self, id: Uuid) -> Result<(), PinkhaError> {
        let path = self.dir.join(format!("{}.json", id));
        std::fs::remove_file(&path).map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                PinkhaError::NotFound(id)
            } else {
                PinkhaError::Io(e)
            }
        })
    }

    fn move_to_shelf(&self, _leaf_id: Uuid, _shelf_id: Option<Uuid>) -> Result<(), PinkhaError> {
        Ok(())
    }

    fn list_by_shelf(&self, _shelf_id: Option<Uuid>) -> Result<Vec<LeafMeta>, PinkhaError> {
        self.list()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::application::error::PinkhaError;
    use crate::domain::leaf::{Leaf, InlineText};
    use uuid::Uuid;

    fn store_temp() -> JsonStore {
        let dir = std::env::temp_dir().join(format!("pinkha_json_{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        JsonStore::new(dir)
    }

    fn doc(title: &str) -> Leaf {
        Leaf::new(vec![InlineText {
            content: title.to_string(),
            styles: vec![],
        }])
    }

    #[test]
    fn test_load_retourne_non_trouve() {
        let store = JsonStore::new(PathBuf::from("/tmp/pinkha_inexistant"));
        let id = Uuid::new_v4();
        assert!(matches!(store.load(id), Err(PinkhaError::NotFound(_))));
    }

    #[test]
    fn test_delete_supprime_le_fichier() {
        let store = store_temp();
        let d = doc("Test");
        store.save(&d).unwrap();
        store.delete(d.id).unwrap();
        assert!(matches!(store.load(d.id), Err(PinkhaError::NotFound(_))));
    }

    #[test]
    fn test_delete_inexistant_retourne_non_trouve() {
        let store = store_temp();
        let id = Uuid::new_v4();
        assert!(matches!(store.delete(id), Err(PinkhaError::NotFound(_))));
    }

    #[test]
    fn test_list_ignore_les_fichiers_corrompus() {
        let store = store_temp();
        store.save(&doc("Sain")).unwrap();
        // Corrupted file: a .json file that cannot be deserialized
        let corrupt = store.dir.join(format!("{}.json", Uuid::new_v4()));
        std::fs::write(&corrupt, "{ pas du JSON valide").unwrap();
        let metas = store.list().unwrap();
        assert_eq!(
            metas.len(),
            1,
            "le fichier sain doit être listé, le corrompu ignoré"
        );
    }

    #[test]
    fn test_list_ignore_les_fichiers_non_json() {
        let store = store_temp();
        store.save(&doc("Sain")).unwrap();
        // Stray files: interrupted .tmp write, file without extension
        std::fs::write(store.dir.join(".abc.json.tmp"), "incomplet").unwrap();
        std::fs::write(store.dir.join("notes.txt"), "rien à voir").unwrap();
        let metas = store.list().unwrap();
        assert_eq!(metas.len(), 1);
    }

    #[test]
    fn test_save_est_atomique() {
        let store = store_temp();
        let d = doc("Atomique");
        store.save(&d).unwrap();
        // No .tmp file should linger after a successful save
        let tmps: Vec<_> = std::fs::read_dir(&store.dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.path().extension().and_then(|x| x.to_str()) == Some("tmp"))
            .collect();
        assert!(
            tmps.is_empty(),
            "aucun .tmp ne doit subsister après save atomique"
        );
    }
}
