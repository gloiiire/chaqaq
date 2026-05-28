use uuid::Uuid;
use crate::application::error::ChaqaqError;
use crate::domain::database::{Database, DatabaseMeta};

pub trait DatabaseRepository {
    fn save(&self, db: &Database) -> Result<(), ChaqaqError>;
    fn load(&self, id: Uuid) -> Result<Database, ChaqaqError>;
    fn list_meta(&self) -> Result<Vec<DatabaseMeta>, ChaqaqError>;
}
