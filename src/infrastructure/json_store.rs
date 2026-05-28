use std::path::PathBuf;
use uuid::Uuid;
use crate::application::repository::DocumentRepository;
use crate::domain::document::Document;

pub struct JsonStore {
    dir: PathBuf,
}

impl JsonStore {
    pub fn new(dir: PathBuf) -> Self {
        Self { dir }
    }
}

impl DocumentRepository for JsonStore {
    fn save(&self, doc: &Document) -> Result<(), Box<dyn std::error::Error>> {
        std::fs::create_dir_all(&self.dir)?;
        let path = self.dir.join(format!("{}.json", doc.id));
        std::fs::write(path, serde_json::to_string_pretty(doc)?)?;
        Ok(())
    }

    fn load(&self, id: Uuid) -> Result<Document, Box<dyn std::error::Error>> {
        let json = std::fs::read_to_string(self.dir.join(format!("{}.json", id)))?;
        Ok(serde_json::from_str(&json)?)
    }

    fn list(&self) -> Result<Vec<Document>, Box<dyn std::error::Error>> {
        std::fs::read_dir(&self.dir)?
            .map(|entry| -> Result<Document, Box<dyn std::error::Error>> {
                let json = std::fs::read_to_string(entry?.path())?;
                Ok(serde_json::from_str(&json)?)
            })
            .collect()
    }
}
