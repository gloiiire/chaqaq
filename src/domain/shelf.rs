use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// A shelf that groups leaves in a tree hierarchy.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Shelf {
    pub id: Uuid,
    pub name: String,
    /// None = root-level shelf.
    pub parent_id: Option<Uuid>,
    pub created_at: String,
    pub updated_at: String,
    /// Optional emoji icon, mirrors `Leaf.icon`.
    #[serde(default)]
    pub icon: Option<String>,
}

/// Lightweight shelf descriptor for list operations.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ShelfMeta {
    pub id: Uuid,
    pub name: String,
    pub parent_id: Option<Uuid>,
    pub updated_at: String,
    pub created_at: String,
    #[serde(default)]
    pub icon: Option<String>,
}

impl Shelf {
    pub fn new(name: &str, parent_id: Option<Uuid>) -> Self {
        let now = chrono::Utc::now().to_rfc3339();
        Self {
            id: Uuid::new_v4(),
            name: name.to_string(),
            parent_id,
            created_at: now.clone(),
            updated_at: now,
            icon: None,
        }
    }
}

impl From<&Shelf> for ShelfMeta {
    fn from(f: &Shelf) -> Self {
        Self {
            id: f.id,
            name: f.name.clone(),
            parent_id: f.parent_id,
            updated_at: f.updated_at.clone(),
            created_at: f.created_at.clone(),
            icon: f.icon.clone(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_creates_root_shelf_with_timestamps() {
        let f = Shelf::new("Inbox", None);
        assert_eq!(f.name, "Inbox");
        assert!(f.parent_id.is_none());
        assert!(!f.created_at.is_empty());
        assert_eq!(f.created_at, f.updated_at);
        assert_ne!(f.id, Uuid::nil());
    }

    #[test]
    fn new_creates_nested_shelf() {
        let parent = Uuid::new_v4();
        let f = Shelf::new("Archive", Some(parent));
        assert_eq!(f.parent_id, Some(parent));
    }

    #[test]
    fn meta_round_trip_preserves_fields() {
        let f = Shelf::new("Projects", None);
        let meta: ShelfMeta = (&f).into();
        assert_eq!(meta.id, f.id);
        assert_eq!(meta.name, f.name);
        assert_eq!(meta.parent_id, f.parent_id);
        assert_eq!(meta.created_at, f.created_at);
        assert_eq!(meta.updated_at, f.updated_at);
    }

    #[test]
    fn shelf_serializes_and_deserializes() {
        let f = Shelf::new("Notes", None);
        let json = serde_json::to_string(&f).expect("serialize");
        let back: Shelf = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(back.id, f.id);
        assert_eq!(back.name, f.name);
    }

    #[test]
    fn shelf_meta_serializes_and_deserializes() {
        let f = Shelf::new("Notes", Some(Uuid::new_v4()));
        let meta: ShelfMeta = (&f).into();
        let json = serde_json::to_string(&meta).expect("serialize");
        let back: ShelfMeta = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(back.id, meta.id);
        assert_eq!(back.parent_id, meta.parent_id);
    }

    #[test]
    fn shelf_clone_is_equal() {
        let f = Shelf::new("X", None);
        let cloned = f.clone();
        assert_eq!(cloned.id, f.id);
        let dbg = format!("{:?}", f);
        assert!(dbg.contains("Shelf"));
    }
}
