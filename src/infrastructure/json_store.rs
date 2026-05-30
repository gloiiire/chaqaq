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
        std::fs::write(path, serde_json::to_string_pretty(doc)?)?;
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
        std::fs::read_dir(&self.dir)?
            .map(|entry| -> Result<DocumentMeta, ChaqaqError> {
                let json = std::fs::read_to_string(entry?.path())?;
                Ok(serde_json::from_str(&json)?)
            })
            .collect()
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
}
