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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_creates_root_folder_with_timestamps() {
        let f = Folder::new("Inbox", None);
        assert_eq!(f.name, "Inbox");
        assert!(f.parent_id.is_none());
        assert!(!f.created_at.is_empty());
        assert_eq!(f.created_at, f.updated_at);
        assert_ne!(f.id, Uuid::nil());
    }

    #[test]
    fn new_creates_nested_folder() {
        let parent = Uuid::new_v4();
        let f = Folder::new("Archive", Some(parent));
        assert_eq!(f.parent_id, Some(parent));
    }

    #[test]
    fn meta_round_trip_preserves_fields() {
        let f = Folder::new("Projects", None);
        let meta: FolderMeta = (&f).into();
        assert_eq!(meta.id, f.id);
        assert_eq!(meta.name, f.name);
        assert_eq!(meta.parent_id, f.parent_id);
        assert_eq!(meta.created_at, f.created_at);
        assert_eq!(meta.updated_at, f.updated_at);
    }

    #[test]
    fn folder_serializes_and_deserializes() {
        let f = Folder::new("Notes", None);
        let json = serde_json::to_string(&f).expect("serialize");
        let back: Folder = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(back.id, f.id);
        assert_eq!(back.name, f.name);
    }

    #[test]
    fn folder_meta_serializes_and_deserializes() {
        let f = Folder::new("Notes", Some(Uuid::new_v4()));
        let meta: FolderMeta = (&f).into();
        let json = serde_json::to_string(&meta).expect("serialize");
        let back: FolderMeta = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(back.id, meta.id);
        assert_eq!(back.parent_id, meta.parent_id);
    }

    #[test]
    fn folder_clone_is_equal() {
        let f = Folder::new("X", None);
        let cloned = f.clone();
        assert_eq!(cloned.id, f.id);
        let dbg = format!("{:?}", f);
        assert!(dbg.contains("Folder"));
    }
}
