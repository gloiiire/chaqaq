use crate::application::error::ChaqaqError;
use crate::application::repository::DocumentRepository;
use crate::domain::document::{Document, DocumentMeta};
use std::path::PathBuf;
use uuid::Uuid;

pub struct JsonStore {
    dir: PathBuf,
}

impl JsonStore {
    pub fn new(dir: PathBuf) -> Self {
        Self { dir }
    }
}

impl DocumentRepository for JsonStore {
    fn save(&self, doc: &Document) -> Result<(), ChaqaqError> {
        std::fs::create_dir_all(&self.dir)?;
        let path = self.dir.join(format!("{}.json", doc.id));
        // Écriture atomique : .tmp puis rename — évite la corruption
        // si le process meurt en cours d'écriture (le fichier final reste l'ancien).
        let tmp = self.dir.join(format!(".{}.json.tmp", doc.id));
        std::fs::write(&tmp, serde_json::to_string_pretty(doc)?)?;
        std::fs::rename(&tmp, &path)?;
        Ok(())
    }

    fn load(&self, id: Uuid) -> Result<Document, ChaqaqError> {
        let path = self.dir.join(format!("{}.json", id));
        let json = std::fs::read_to_string(&path).map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                ChaqaqError::NotFound(id)
            } else {
                ChaqaqError::Io(e)
            }
        })?;
        Ok(serde_json::from_str(&json)?)
    }

    fn list(&self) -> Result<Vec<DocumentMeta>, ChaqaqError> {
        // On filtre sur l'extension `.json` (les .tmp d'écritures interrompues sont ignorés)
        // et on ignore silencieusement les fichiers corrompus pour ne pas casser
        // tout le listing à cause d'un seul fichier endommagé.
        let mut metas = Vec::new();
        for entry in std::fs::read_dir(&self.dir)? {
            let path = entry?.path();
            if path.extension().and_then(|e| e.to_str()) != Some("json") {
                continue;
            }
            if let Ok(json) = std::fs::read_to_string(&path) {
                if let Ok(meta) = serde_json::from_str::<DocumentMeta>(&json) {
                    metas.push(meta);
                }
            }
        }
        Ok(metas)
    }

    fn delete(&self, id: Uuid) -> Result<(), ChaqaqError> {
        let path = self.dir.join(format!("{}.json", id));
        std::fs::remove_file(&path).map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                ChaqaqError::NotFound(id)
            } else {
                ChaqaqError::Io(e)
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::application::error::ChaqaqError;
    use crate::domain::document::{Document, InlineText};
    use uuid::Uuid;

    fn store_temp() -> JsonStore {
        let dir = std::env::temp_dir().join(format!("chaqaq_json_{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        JsonStore::new(dir)
    }

    fn doc(title: &str) -> Document {
        Document::new(vec![InlineText {
            content: title.to_string(),
            styles: vec![],
        }])
    }

    #[test]
    fn test_load_retourne_non_trouve() {
        let store = JsonStore::new(PathBuf::from("/tmp/chaqaq_inexistant"));
        let id = Uuid::new_v4();
        assert!(matches!(store.load(id), Err(ChaqaqError::NotFound(_))));
    }

    #[test]
    fn test_delete_supprime_le_fichier() {
        let store = store_temp();
        let d = doc("Test");
        store.save(&d).unwrap();
        store.delete(d.id).unwrap();
        assert!(matches!(store.load(d.id), Err(ChaqaqError::NotFound(_))));
    }

    #[test]
    fn test_delete_inexistant_retourne_non_trouve() {
        let store = store_temp();
        let id = Uuid::new_v4();
        assert!(matches!(store.delete(id), Err(ChaqaqError::NotFound(_))));
    }

    #[test]
    fn test_list_ignore_les_fichiers_corrompus() {
        let store = store_temp();
        store.save(&doc("Sain")).unwrap();
        // Fichier corrompu : un .json non-déserialisable
        let corrupt = store.dir.join(format!("{}.json", Uuid::new_v4()));
        std::fs::write(&corrupt, "{ pas du JSON valide").unwrap();
        let metas = store.list().unwrap();
        assert_eq!(metas.len(), 1, "le fichier sain doit être listé, le corrompu ignoré");
    }

    #[test]
    fn test_list_ignore_les_fichiers_non_json() {
        let store = store_temp();
        store.save(&doc("Sain")).unwrap();
        // Fichiers parasites : .tmp d'écriture interrompue, fichier sans extension
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
        // Aucun .tmp ne doit traîner après un save réussi
        let tmps: Vec<_> = std::fs::read_dir(&store.dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.path().extension().and_then(|x| x.to_str()) == Some("tmp"))
            .collect();
        assert!(tmps.is_empty(), "aucun .tmp ne doit subsister après save atomique");
    }
}
