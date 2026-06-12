//! Database, entry, property and view operations on the [`PinkhaApi`] facade.

use std::collections::HashMap;

use uuid::Uuid;

use crate::application::{database_use_cases, use_cases};
use crate::domain::database::{Aggregate, Entry, Filter, Property, PropertyValue, Sort, View};
use crate::domain::parser::parse_inline;

use super::types::{DatabaseMetaFfi, db_meta_to_ffi};
use super::validation::{parse_json, parse_uuid, to_json, validate_string};
use super::{PinkhaApi, PinkhaError};

impl PinkhaApi {
    /// Creates a new database with a plain-text title parsed into inline spans.
    /// Returns the UUID string of the created database.
    pub fn create_database(&self, title: String) -> Result<String, PinkhaError> {
        validate_string(&title, "title")?;
        let db = database_use_cases::create_database(&self.uow(), parse_inline(&title), vec![])
            .map_err(PinkhaError::from)?;
        Ok(db.id.to_string())
    }

    /// Returns the full database as a JSON string.
    pub fn get_database_json(&self, id: String) -> Result<String, PinkhaError> {
        let uuid = parse_uuid(&id)?;
        let db = database_use_cases::get_database(&self.uow(), uuid).map_err(PinkhaError::from)?;
        serde_json::to_string(&db).map_err(|e| PinkhaError::Storage {
            detail: e.to_string(),
        })
    }

    /// Returns lightweight metadata for all non-deleted databases.
    pub fn list_databases(&self) -> Result<Vec<DatabaseMetaFfi>, PinkhaError> {
        let metas = database_use_cases::list_databases(&self.uow()).map_err(PinkhaError::from)?;
        Ok(metas.into_iter().map(db_meta_to_ffi).collect())
    }

    /// Replaces the database's title with `new_title` parsed into inline spans.
    pub fn update_database_title(&self, id: String, new_title: String) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        validate_string(&new_title, "new_title")?;
        database_use_cases::update_database_title(&self.uow(), uuid, parse_inline(&new_title))
            .map_err(PinkhaError::from)
    }

    /// Replaces or clears the database's cover image identifier.
    pub fn update_database_cover(
        &self,
        id: String,
        cover: Option<String>,
    ) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        if let Some(ref c) = cover {
            validate_string(c, "cover")?;
        }
        database_use_cases::update_database_cover(&self.uow(), uuid, cover)
            .map_err(PinkhaError::from)
    }

    /// Replaces or clears the database's icon (emoji / filename / URL).
    pub fn update_database_icon(
        &self,
        id: String,
        icon: Option<String>,
    ) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        if let Some(ref i) = icon {
            validate_string(i, "icon")?;
        }
        database_use_cases::update_database_icon(&self.uow(), uuid, icon).map_err(PinkhaError::from)
    }

    /// Replaces the database's rich-text description. Empty string clears it.
    pub fn update_database_description(
        &self,
        id: String,
        description: String,
    ) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        validate_string(&description, "description")?;
        let spans = if description.is_empty() {
            vec![]
        } else {
            parse_inline(&description)
        };
        database_use_cases::update_database_description(&self.uow(), uuid, spans)
            .map_err(PinkhaError::from)
    }

    /// Flips the database's `locked` flag.
    pub fn update_database_locked(&self, id: String, locked: bool) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        database_use_cases::update_database_locked(&self.uow(), uuid, locked)
            .map_err(PinkhaError::from)
    }

    /// Soft-deletes the database identified by `id`.
    pub fn delete_database(&self, id: String) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        database_use_cases::delete_database(&self.uow(), uuid).map_err(PinkhaError::from)
    }

    /// Soft-deletes every database. Returns the number deleted.
    pub fn delete_all_databases(&self) -> Result<u32, PinkhaError> {
        let metas = database_use_cases::list_databases(&self.uow()).map_err(PinkhaError::from)?;
        let count = metas.len() as u32;
        for meta in metas {
            database_use_cases::delete_database(&self.uow(), meta.id).map_err(PinkhaError::from)?;
        }
        Ok(count)
    }

    /// Adds an entry to a database. `values_json` must be a JSON-encoded
    /// `HashMap<Uuid, PropertyValue>`. Returns the new entry UUID string.
    pub fn add_entry(&self, db_id: String, values_json: String) -> Result<String, PinkhaError> {
        let db_uuid = parse_uuid(&db_id)?;
        let values: HashMap<Uuid, PropertyValue> = parse_json(&values_json)?;
        let entry = database_use_cases::add_entry(&self.uow(), db_uuid, values)
            .map_err(PinkhaError::from)?;
        Ok(entry.id.to_string())
    }

    /// Files an existing document as a row of an existing database.
    /// The new entry stores `document_id` so the Title column stays
    /// linked to the doc's title (the `update_entry_propagating_title`
    /// path keeps them in sync going forward). Returns the new entry
    /// UUID.
    pub fn attach_document_to_database(
        &self,
        db_id: String,
        doc_id: String,
        values_json: String,
    ) -> Result<String, PinkhaError> {
        let db_uuid = parse_uuid(&db_id)?;
        let doc_uuid = parse_uuid(&doc_id)?;
        let values: HashMap<Uuid, PropertyValue> = parse_json(&values_json)?;
        let entry =
            database_use_cases::add_entry_with_document(&self.uow(), db_uuid, values, doc_uuid)
                .map_err(PinkhaError::from)?;
        Ok(entry.id.to_string())
    }

    /// Replaces all property values of an existing entry. When the entry is
    /// linked to a document and the new values touch the Title property, the
    /// document title is updated in lockstep — fixing the UX bug where
    /// renaming a row in the DB view left the underlying note's title stale.
    pub fn update_entry(
        &self,
        db_id: String,
        entry_id: String,
        values_json: String,
    ) -> Result<(), PinkhaError> {
        let db_uuid = parse_uuid(&db_id)?;
        let entry_uuid = parse_uuid(&entry_id)?;
        let values: HashMap<Uuid, PropertyValue> = parse_json(&values_json)?;
        use_cases::update_entry_propagating_title(&self.uow(), db_uuid, entry_uuid, values)
            .map_err(PinkhaError::from)
    }

    /// Overrides the entry's user-editable `published_at`. Pass an
    /// empty string to reset to the default "follow `created_at`"
    /// behaviour.
    pub fn update_entry_published_at(
        &self,
        db_id: String,
        entry_id: String,
        new_published_at: String,
    ) -> Result<(), PinkhaError> {
        let db_uuid = parse_uuid(&db_id)?;
        let entry_uuid = parse_uuid(&entry_id)?;
        // Allow the empty-string reset path — `validate_string`
        // refuses empty but we want it here. Bound the upper size to
        // a sane RFC 3339 length.
        if new_published_at.len() > 64 {
            return Err(PinkhaError::InvalidOperation {
                detail: "published_at too long".to_string(),
            });
        }
        database_use_cases::update_entry_published_at(
            &self.uow(),
            db_uuid,
            entry_uuid,
            new_published_at,
        )
        .map_err(PinkhaError::from)
    }

    /// Soft-deletes an entry — recoverable via `restore_entry`.
    pub fn delete_entry(&self, db_id: String, entry_id: String) -> Result<(), PinkhaError> {
        let db_uuid = parse_uuid(&db_id)?;
        let entry_uuid = parse_uuid(&entry_id)?;
        database_use_cases::delete_entry(&self.uow(), db_uuid, entry_uuid)
            .map_err(PinkhaError::from)
    }

    /// Restores a soft-deleted entry.
    pub fn restore_entry(&self, db_id: String, entry_id: String) -> Result<(), PinkhaError> {
        let db_uuid = parse_uuid(&db_id)?;
        let entry_uuid = parse_uuid(&entry_id)?;
        database_use_cases::restore_entry(&self.uow(), db_uuid, entry_uuid)
            .map_err(PinkhaError::from)
    }

    /// Permanently deletes a soft-deleted entry (purge from trash).
    pub fn purge_entry(&self, db_id: String, entry_id: String) -> Result<(), PinkhaError> {
        let db_uuid = parse_uuid(&db_id)?;
        let entry_uuid = parse_uuid(&entry_id)?;
        database_use_cases::purge_entry(&self.uow(), db_uuid, entry_uuid).map_err(PinkhaError::from)
    }

    /// Lists soft-deleted entries of a database as a JSON array.
    pub fn list_deleted_entries_json(&self, db_id: String) -> Result<String, PinkhaError> {
        let db_uuid = parse_uuid(&db_id)?;
        let entries = database_use_cases::list_deleted_entries(&self.uow(), db_uuid)
            .map_err(PinkhaError::from)?;
        to_json(&entries)
    }

    /// Lists soft-deleted databases (the trash). Newest-deleted first.
    pub fn list_deleted_databases(&self) -> Result<Vec<DatabaseMetaFfi>, PinkhaError> {
        let metas =
            database_use_cases::list_deleted_databases(&self.uow()).map_err(PinkhaError::from)?;
        Ok(metas.into_iter().map(db_meta_to_ffi).collect())
    }

    /// Restores a soft-deleted database.
    pub fn restore_database(&self, id: String) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        database_use_cases::restore_database(&self.uow(), uuid).map_err(PinkhaError::from)
    }

    /// Permanently deletes a soft-deleted database (purge from trash).
    pub fn purge_database(&self, id: String) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        database_use_cases::purge_database(&self.uow(), uuid).map_err(PinkhaError::from)
    }

    /// Adds a property to an existing database. `property_json` must be a
    /// JSON-encoded [`Property`].
    pub fn add_property(&self, db_id: String, property_json: String) -> Result<(), PinkhaError> {
        let db_uuid = parse_uuid(&db_id)?;
        let property: Property = parse_json(&property_json)?;
        database_use_cases::add_property(&self.uow(), db_uuid, property).map_err(PinkhaError::from)
    }

    /// Renames a property in an existing database.
    pub fn rename_property(
        &self,
        db_id: String,
        property_id: String,
        new_name: String,
    ) -> Result<(), PinkhaError> {
        validate_string(&new_name, "new_name")?;
        let db_uuid = parse_uuid(&db_id)?;
        let prop_uuid = parse_uuid(&property_id)?;
        database_use_cases::rename_property(&self.uow(), db_uuid, prop_uuid, &new_name)
            .map_err(PinkhaError::from)
    }

    /// Removes a property from a database and clears its values in all entries.
    pub fn delete_property(&self, db_id: String, property_id: String) -> Result<(), PinkhaError> {
        let db_uuid = parse_uuid(&db_id)?;
        let prop_uuid = parse_uuid(&property_id)?;
        database_use_cases::delete_property(&self.uow(), db_uuid, prop_uuid)
            .map_err(PinkhaError::from)
    }

    /// Adds a view to a database. `view_json` must be a JSON-encoded [`View`].
    /// Returns the new view UUID string.
    pub fn add_view(&self, db_id: String, view_json: String) -> Result<String, PinkhaError> {
        let db_uuid = parse_uuid(&db_id)?;
        let view: View = parse_json(&view_json)?;
        let view =
            database_use_cases::add_view(&self.uow(), db_uuid, view).map_err(PinkhaError::from)?;
        Ok(view.id.to_string())
    }

    /// Updates the filters and sorts of an existing view.
    pub fn update_view(
        &self,
        db_id: String,
        view_id: String,
        filters_json: String,
        sorts_json: String,
    ) -> Result<(), PinkhaError> {
        let db_uuid = parse_uuid(&db_id)?;
        let view_uuid = parse_uuid(&view_id)?;
        let filters: Vec<Filter> = parse_json(&filters_json)?;
        let sorts: Vec<Sort> = parse_json(&sorts_json)?;
        database_use_cases::update_view(&self.uow(), db_uuid, view_uuid, filters, sorts)
            .map_err(PinkhaError::from)
    }

    /// Sets a single sort on a view, replacing previous sorts. `property_id`
    /// = `None` clears the sort. Used by the DB view column-header tap
    /// gesture — callers don't have to know the `Sort`/`SortSource` JSON
    /// shape, the orchestration lives in Rust.
    pub fn set_view_sort(
        &self,
        db_id: String,
        view_id: String,
        property_id: Option<String>,
        ascending: bool,
    ) -> Result<(), PinkhaError> {
        let db_uuid = parse_uuid(&db_id)?;
        let view_uuid = parse_uuid(&view_id)?;
        let prop_uuid = property_id.as_deref().map(parse_uuid).transpose()?;
        database_use_cases::set_view_single_sort(
            &self.uow(),
            db_uuid,
            view_uuid,
            prop_uuid,
            ascending,
        )
        .map_err(PinkhaError::from)
    }

    /// Sets the view's sort to the entry-level `created_at` or
    /// `published_at` timestamp. `kind` accepts `"created"` or
    /// `"published"` (case-insensitive). For column-based sorts,
    /// use `set_view_sort` with a `property_id` instead.
    pub fn set_view_date_sort(
        &self,
        db_id: String,
        view_id: String,
        kind: String,
        ascending: bool,
    ) -> Result<(), PinkhaError> {
        let db_uuid = parse_uuid(&db_id)?;
        let view_uuid = parse_uuid(&view_id)?;
        let source = match kind.to_lowercase().as_str() {
            "created" => crate::domain::database::SortSource::Created,
            "published" => crate::domain::database::SortSource::Published,
            other => {
                return Err(PinkhaError::InvalidOperation {
                    detail: format!("unsupported date sort kind: {other}"),
                });
            }
        };
        database_use_cases::set_view_date_sort(&self.uow(), db_uuid, view_uuid, source, ascending)
            .map_err(PinkhaError::from)
    }

    /// Removes a view from a database. Fails if it is the last view.
    pub fn delete_view(&self, db_id: String, view_id: String) -> Result<(), PinkhaError> {
        let db_uuid = parse_uuid(&db_id)?;
        let view_uuid = parse_uuid(&view_id)?;
        database_use_cases::delete_view(&self.uow(), db_uuid, view_uuid).map_err(PinkhaError::from)
    }

    /// Runs the filters and sorts defined on a view and returns matching entries
    /// as a JSON array.
    pub fn query_database_json(
        &self,
        db_id: String,
        view_id: String,
    ) -> Result<String, PinkhaError> {
        let db_uuid = parse_uuid(&db_id)?;
        let view_uuid = parse_uuid(&view_id)?;
        let entries: Vec<Entry> = database_use_cases::query(&self.uow(), db_uuid, view_uuid)
            .map_err(PinkhaError::from)?;
        to_json(&entries)
    }

    /// Same as [`query_database_json`] but with rollup columns computed at read
    /// time.
    pub fn query_database_with_rollups_json(
        &self,
        db_id: String,
        view_id: String,
    ) -> Result<String, PinkhaError> {
        let db_uuid = parse_uuid(&db_id)?;
        let view_uuid = parse_uuid(&view_id)?;
        let entries: Vec<Entry> =
            database_use_cases::query_with_rollups(&self.uow(), db_uuid, view_uuid)
                .map_err(PinkhaError::from)?;
        to_json(&entries)
    }

    /// Groups entries by `group_by` property and returns a JSON array of groups.
    pub fn grouped_query_database_json(
        &self,
        db_id: String,
        view_id: String,
        group_by: String,
    ) -> Result<String, PinkhaError> {
        let db_uuid = parse_uuid(&db_id)?;
        let view_uuid = parse_uuid(&view_id)?;
        let prop_uuid = parse_uuid(&group_by)?;
        let groups = database_use_cases::grouped_query(&self.uow(), db_uuid, view_uuid, prop_uuid)
            .map_err(PinkhaError::from)?;
        to_json(&groups)
    }

    /// Computes a column aggregate and returns the result as a JSON-encoded
    /// [`PropertyValue`].
    pub fn column_aggregate_database_json(
        &self,
        db_id: String,
        property_id: String,
        aggregate_json: String,
    ) -> Result<String, PinkhaError> {
        let db_uuid = parse_uuid(&db_id)?;
        let prop_uuid = parse_uuid(&property_id)?;
        let aggregate: Aggregate = parse_json(&aggregate_json)?;
        let value =
            database_use_cases::column_aggregate(&self.uow(), db_uuid, prop_uuid, aggregate)
                .map_err(PinkhaError::from)?;
        to_json(&value)
    }

    /// Searches all text-valued properties of a database's entries for `query`
    /// (case-insensitive). Returns matching entries as a JSON array.
    pub fn search_database_entries_json(
        &self,
        db_id: String,
        query: String,
    ) -> Result<String, PinkhaError> {
        validate_string(&query, "query")?;
        let db_uuid = parse_uuid(&db_id)?;
        let entries = database_use_cases::search_entries(&self.uow(), db_uuid, &query)
            .map_err(PinkhaError::from)?;
        to_json(&entries)
    }

    /// Creates a fresh document and files it as a new row of `db_id` in a
    /// single call — fills the hidden page-link column and the Title
    /// column automatically when the schema defines them. `values_json`
    /// carries any extra column values (same shape as `add_entry`).
    /// Returns the new document's UUID string.
    pub fn create_document_in_database(
        &self,
        db_id: String,
        title: String,
        values_json: String,
    ) -> Result<String, PinkhaError> {
        validate_string(&title, "title")?;
        let db_uuid = parse_uuid(&db_id)?;
        let values: HashMap<Uuid, PropertyValue> = parse_json(&values_json)?;
        let (doc_id, _entry_id) =
            use_cases::create_document_in_database(&self.uow(), db_uuid, &title, values)
                .map_err(PinkhaError::from)?;
        Ok(doc_id.to_string())
    }
}
