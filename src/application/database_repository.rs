use crate::application::error::PinkhaError;
use crate::domain::database::{Database, DatabaseMeta};
use uuid::Uuid;

pub trait DatabaseRepository {
    fn save(&self, db: &Database) -> Result<(), PinkhaError>;
    fn load(&self, id: Uuid) -> Result<Database, PinkhaError>;
    fn list_meta(&self) -> Result<Vec<DatabaseMeta>, PinkhaError>;
    fn delete(&self, id: Uuid) -> Result<(), PinkhaError>;
}
