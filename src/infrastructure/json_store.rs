use std::path::PathBuf;
use uuid::Uuid;
use crate::application::error::ChaqaqError;
use crate::application::repository::DocumentRepository;
use crate::domain::document::{Document, DocumentMeta};

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
                ChaqaqError::NonTrouve(id)
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
}
