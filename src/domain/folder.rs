use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// A folder that groups documents in a tree hierarchy.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Folder {
    pub id: Uuid,
    pub name: String,
    /// None = root-level folder.
    pub parent_id: Option<Uuid>,
    pub created_at: String,
    pub updated_at: String,
}

/// Lightweight folder descriptor for list operations.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FolderMeta {
    pub id: Uuid,
    pub name: String,
    pub parent_id: Option<Uuid>,
    pub updated_at: String,
    pub created_at: String,
}

impl Folder {
    pub fn new(name: &str, parent_id: Option<Uuid>) -> Self {
        let now = chrono::Utc::now().to_rfc3339();
        Self {
            id: Uuid::new_v4(),
            name: name.to_string(),
            parent_id,
            created_at: now.clone(),
            updated_at: now,
        }
    }
}

impl From<&Folder> for FolderMeta {
    fn from(f: &Folder) -> Self {
        Self {
            id: f.id,
            name: f.name.clone(),
            parent_id: f.parent_id,
            updated_at: f.updated_at.clone(),
            created_at: f.created_at.clone(),
        }
    }
}
