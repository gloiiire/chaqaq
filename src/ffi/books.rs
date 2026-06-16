//! Book, entry, property and view operations on the [`PinkhaApi`] facade.

use std::collections::HashMap;

use uuid::Uuid;

use crate::application::{book_use_cases, use_cases};
use crate::domain::book::{Aggregate, Entry, Filter, Property, PropertyValue, Sort, View};
use crate::domain::parser::parse_inline;

use super::types::{BookMetaFfi, book_meta_to_ffi};
use super::validation::{parse_json, parse_uuid, to_json, validate_string};
use super::{PinkhaApi, PinkhaError};

impl PinkhaApi {
    /// Creates a new book with a plain-text title parsed into inline spans.
    /// Returns the UUID string of the created book.
    pub fn create_book(&self, title: String) -> Result<String, PinkhaError> {
        validate_string(&title, "title")?;
        let db = book_use_cases::create_book(&self.uow(), parse_inline(&title), vec![])
            .map_err(PinkhaError::from)?;
        Ok(db.id.to_string())
    }

    /// Returns the full book as a JSON string.
    pub fn get_book_json(&self, id: String) -> Result<String, PinkhaError> {
        let uuid = parse_uuid(&id)?;
        let db = book_use_cases::get_book(&self.uow(), uuid).map_err(PinkhaError::from)?;
        serde_json::to_string(&db).map_err(|e| PinkhaError::Storage {
            detail: e.to_string(),
        })
    }

    /// Returns lightweight metadata for all non-deleted books.
    pub fn list_books(&self) -> Result<Vec<BookMetaFfi>, PinkhaError> {
        let metas = book_use_cases::list_books(&self.uow()).map_err(PinkhaError::from)?;
        Ok(metas.into_iter().map(book_meta_to_ffi).collect())
    }

    /// Replaces the book's title with `new_title` parsed into inline spans.
    pub fn update_book_title(&self, id: String, new_title: String) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        validate_string(&new_title, "new_title")?;
        book_use_cases::update_book_title(&self.uow(), uuid, parse_inline(&new_title))
            .map_err(PinkhaError::from)
    }

    /// Replaces or clears the book's cover image identifier.
    pub fn update_book_cover(
        &self,
        id: String,
        cover: Option<String>,
    ) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        if let Some(ref c) = cover {
            validate_string(c, "cover")?;
        }
        book_use_cases::update_book_cover(&self.uow(), uuid, cover)
            .map_err(PinkhaError::from)
    }

    /// Replaces or clears the book's icon (emoji / filename / URL).
    pub fn update_book_icon(
        &self,
        id: String,
        icon: Option<String>,
    ) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        if let Some(ref i) = icon {
            validate_string(i, "icon")?;
        }
        book_use_cases::update_book_icon(&self.uow(), uuid, icon).map_err(PinkhaError::from)
    }

    /// Replaces the book's rich-text description. Empty string clears it.
    pub fn update_book_description(
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
        book_use_cases::update_book_description(&self.uow(), uuid, spans)
            .map_err(PinkhaError::from)
    }

    /// Flips the book's `locked` flag.
    pub fn update_book_locked(&self, id: String, locked: bool) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        book_use_cases::update_book_locked(&self.uow(), uuid, locked)
            .map_err(PinkhaError::from)
    }

    /// Soft-deletes the book identified by `id`.
    pub fn delete_book(&self, id: String) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        book_use_cases::delete_book(&self.uow(), uuid).map_err(PinkhaError::from)
    }

    /// Soft-deletes the book AND every leaf its rows are backed
    /// by. Returns the number of leaves deleted alongside it.
    pub fn delete_book_cascade(&self, id: String) -> Result<u32, PinkhaError> {
        let uuid = parse_uuid(&id)?;
        use_cases::delete_book_cascade(&self.uow(), uuid).map_err(PinkhaError::from)
    }

    /// Restores a soft-deleted book AND every leaf its rows are
    /// backed by. Returns the number of leaves restored alongside it.
    pub fn restore_book_cascade(&self, id: String) -> Result<u32, PinkhaError> {
        let uuid = parse_uuid(&id)?;
        use_cases::restore_book_cascade(&self.uow(), uuid).map_err(PinkhaError::from)
    }

    /// Soft-deletes every book. Returns the number deleted.
    pub fn delete_all_books(&self) -> Result<u32, PinkhaError> {
        let metas = book_use_cases::list_books(&self.uow()).map_err(PinkhaError::from)?;
        let count = metas.len() as u32;
        for meta in metas {
            book_use_cases::delete_book(&self.uow(), meta.id).map_err(PinkhaError::from)?;
        }
        Ok(count)
    }

    /// Adds an entry to a book. `values_json` must be a JSON-encoded
    /// `HashMap<Uuid, PropertyValue>`. Returns the new entry UUID string.
    pub fn add_entry(&self, book_id: String, values_json: String) -> Result<String, PinkhaError> {
        let book_uuid = parse_uuid(&book_id)?;
        let values: HashMap<Uuid, PropertyValue> = parse_json(&values_json)?;
        let entry = book_use_cases::add_entry(&self.uow(), book_uuid, values)
            .map_err(PinkhaError::from)?;
        Ok(entry.id.to_string())
    }

    /// Files an existing leaf as a row of an existing book.
    /// The new entry stores `leaf_id` so the Title column stays
    /// linked to the doc's title (the `update_entry_propagating_title`
    /// path keeps them in sync going forward). Returns the new entry
    /// UUID.
    pub fn attach_leaf_to_book(
        &self,
        book_id: String,
        leaf_id: String,
        values_json: String,
    ) -> Result<String, PinkhaError> {
        let book_uuid = parse_uuid(&book_id)?;
        let leaf_uuid = parse_uuid(&leaf_id)?;
        let values: HashMap<Uuid, PropertyValue> = parse_json(&values_json)?;
        let entry =
            book_use_cases::add_entry_with_leaf(&self.uow(), book_uuid, values, leaf_uuid)
                .map_err(PinkhaError::from)?;
        Ok(entry.id.to_string())
    }

    /// Replaces all property values of an existing entry. When the entry is
    /// linked to a leaf and the new values touch the Title property, the
    /// leaf title is updated in lockstep — fixing the UX bug where
    /// renaming a row in the DB view left the underlying note's title stale.
    pub fn update_entry(
        &self,
        book_id: String,
        entry_id: String,
        values_json: String,
    ) -> Result<(), PinkhaError> {
        let book_uuid = parse_uuid(&book_id)?;
        let entry_uuid = parse_uuid(&entry_id)?;
        let values: HashMap<Uuid, PropertyValue> = parse_json(&values_json)?;
        use_cases::update_entry_propagating_title(&self.uow(), book_uuid, entry_uuid, values)
            .map_err(PinkhaError::from)
    }

    /// Overrides the entry's user-editable `published_at`. Pass an
    /// empty string to reset to the default "follow `created_at`"
    /// behaviour.
    pub fn update_entry_published_at(
        &self,
        book_id: String,
        entry_id: String,
        new_published_at: String,
    ) -> Result<(), PinkhaError> {
        let book_uuid = parse_uuid(&book_id)?;
        let entry_uuid = parse_uuid(&entry_id)?;
        // Allow the empty-string reset path — `validate_string`
        // refuses empty but we want it here. Bound the upper size to
        // a sane RFC 3339 length.
        if new_published_at.len() > 64 {
            return Err(PinkhaError::InvalidOperation {
                detail: "published_at too long".to_string(),
            });
        }
        book_use_cases::update_entry_published_at(
            &self.uow(),
            book_uuid,
            entry_uuid,
            new_published_at,
        )
        .map_err(PinkhaError::from)
    }

    /// Soft-deletes an entry — recoverable via `restore_entry`.
    pub fn delete_entry(&self, book_id: String, entry_id: String) -> Result<(), PinkhaError> {
        let book_uuid = parse_uuid(&book_id)?;
        let entry_uuid = parse_uuid(&entry_id)?;
        book_use_cases::delete_entry(&self.uow(), book_uuid, entry_uuid)
            .map_err(PinkhaError::from)
    }

    /// Restores a soft-deleted entry.
    pub fn restore_entry(&self, book_id: String, entry_id: String) -> Result<(), PinkhaError> {
        let book_uuid = parse_uuid(&book_id)?;
        let entry_uuid = parse_uuid(&entry_id)?;
        book_use_cases::restore_entry(&self.uow(), book_uuid, entry_uuid)
            .map_err(PinkhaError::from)
    }

    /// Permanently deletes a soft-deleted entry (purge from trash).
    pub fn purge_entry(&self, book_id: String, entry_id: String) -> Result<(), PinkhaError> {
        let book_uuid = parse_uuid(&book_id)?;
        let entry_uuid = parse_uuid(&entry_id)?;
        book_use_cases::purge_entry(&self.uow(), book_uuid, entry_uuid).map_err(PinkhaError::from)
    }

    /// Lists soft-deleted entries of a book as a JSON array.
    pub fn list_deleted_entries_json(&self, book_id: String) -> Result<String, PinkhaError> {
        let book_uuid = parse_uuid(&book_id)?;
        let entries = book_use_cases::list_deleted_entries(&self.uow(), book_uuid)
            .map_err(PinkhaError::from)?;
        to_json(&entries)
    }

    /// Lists soft-deleted books (the trash). Newest-deleted first.
    pub fn list_deleted_books(&self) -> Result<Vec<BookMetaFfi>, PinkhaError> {
        let metas =
            book_use_cases::list_deleted_books(&self.uow()).map_err(PinkhaError::from)?;
        Ok(metas.into_iter().map(book_meta_to_ffi).collect())
    }

    /// Restores a soft-deleted book.
    pub fn restore_book(&self, id: String) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        book_use_cases::restore_book(&self.uow(), uuid).map_err(PinkhaError::from)
    }

    /// Permanently deletes a soft-deleted book (purge from trash).
    pub fn purge_book(&self, id: String) -> Result<(), PinkhaError> {
        let uuid = parse_uuid(&id)?;
        book_use_cases::purge_book(&self.uow(), uuid).map_err(PinkhaError::from)
    }

    /// Adds a property to an existing book. `property_json` must be a
    /// JSON-encoded [`Property`].
    pub fn add_property(&self, book_id: String, property_json: String) -> Result<(), PinkhaError> {
        let book_uuid = parse_uuid(&book_id)?;
        let property: Property = parse_json(&property_json)?;
        book_use_cases::add_property(&self.uow(), book_uuid, property).map_err(PinkhaError::from)
    }

    /// Renames a property in an existing book.
    pub fn rename_property(
        &self,
        book_id: String,
        property_id: String,
        new_name: String,
    ) -> Result<(), PinkhaError> {
        validate_string(&new_name, "new_name")?;
        let book_uuid = parse_uuid(&book_id)?;
        let prop_uuid = parse_uuid(&property_id)?;
        book_use_cases::rename_property(&self.uow(), book_uuid, prop_uuid, &new_name)
            .map_err(PinkhaError::from)
    }

    /// Removes a property from a book and clears its values in all entries.
    pub fn delete_property(&self, book_id: String, property_id: String) -> Result<(), PinkhaError> {
        let book_uuid = parse_uuid(&book_id)?;
        let prop_uuid = parse_uuid(&property_id)?;
        book_use_cases::delete_property(&self.uow(), book_uuid, prop_uuid)
            .map_err(PinkhaError::from)
    }

    /// Adds a view to a book. `view_json` must be a JSON-encoded [`View`].
    /// Returns the new view UUID string.
    pub fn add_view(&self, book_id: String, view_json: String) -> Result<String, PinkhaError> {
        let book_uuid = parse_uuid(&book_id)?;
        let view: View = parse_json(&view_json)?;
        let view =
            book_use_cases::add_view(&self.uow(), book_uuid, view).map_err(PinkhaError::from)?;
        Ok(view.id.to_string())
    }

    /// Updates the filters and sorts of an existing view.
    pub fn update_view(
        &self,
        book_id: String,
        view_id: String,
        filters_json: String,
        sorts_json: String,
    ) -> Result<(), PinkhaError> {
        let book_uuid = parse_uuid(&book_id)?;
        let view_uuid = parse_uuid(&view_id)?;
        let filters: Vec<Filter> = parse_json(&filters_json)?;
        let sorts: Vec<Sort> = parse_json(&sorts_json)?;
        book_use_cases::update_view(&self.uow(), book_uuid, view_uuid, filters, sorts)
            .map_err(PinkhaError::from)
    }

    /// Sets a single sort on a view, replacing previous sorts. `property_id`
    /// = `None` clears the sort. Used by the DB view column-header tap
    /// gesture — callers don't have to know the `Sort`/`SortSource` JSON
    /// shape, the orchestration lives in Rust.
    pub fn set_view_sort(
        &self,
        book_id: String,
        view_id: String,
        property_id: Option<String>,
        ascending: bool,
    ) -> Result<(), PinkhaError> {
        let book_uuid = parse_uuid(&book_id)?;
        let view_uuid = parse_uuid(&view_id)?;
        let prop_uuid = property_id.as_deref().map(parse_uuid).transpose()?;
        book_use_cases::set_view_single_sort(
            &self.uow(),
            book_uuid,
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
        book_id: String,
        view_id: String,
        kind: String,
        ascending: bool,
    ) -> Result<(), PinkhaError> {
        let book_uuid = parse_uuid(&book_id)?;
        let view_uuid = parse_uuid(&view_id)?;
        let source = match kind.to_lowercase().as_str() {
            "created" => crate::domain::book::SortSource::Created,
            "published" => crate::domain::book::SortSource::Published,
            other => {
                return Err(PinkhaError::InvalidOperation {
                    detail: format!("unsupported date sort kind: {other}"),
                });
            }
        };
        book_use_cases::set_view_date_sort(&self.uow(), book_uuid, view_uuid, source, ascending)
            .map_err(PinkhaError::from)
    }

    /// Removes a view from a book. Fails if it is the last view.
    pub fn delete_view(&self, book_id: String, view_id: String) -> Result<(), PinkhaError> {
        let book_uuid = parse_uuid(&book_id)?;
        let view_uuid = parse_uuid(&view_id)?;
        book_use_cases::delete_view(&self.uow(), book_uuid, view_uuid).map_err(PinkhaError::from)
    }

    /// Runs the filters and sorts defined on a view and returns matching entries
    /// as a JSON array.
    pub fn query_book_json(
        &self,
        book_id: String,
        view_id: String,
    ) -> Result<String, PinkhaError> {
        let book_uuid = parse_uuid(&book_id)?;
        let view_uuid = parse_uuid(&view_id)?;
        let entries: Vec<Entry> = book_use_cases::query(&self.uow(), book_uuid, view_uuid)
            .map_err(PinkhaError::from)?;
        to_json(&entries)
    }

    /// Same as [`query_book_json`] but with rollup columns computed at read
    /// time.
    pub fn query_book_with_rollups_json(
        &self,
        book_id: String,
        view_id: String,
    ) -> Result<String, PinkhaError> {
        let book_uuid = parse_uuid(&book_id)?;
        let view_uuid = parse_uuid(&view_id)?;
        let entries: Vec<Entry> =
            book_use_cases::query_with_rollups(&self.uow(), book_uuid, view_uuid)
                .map_err(PinkhaError::from)?;
        to_json(&entries)
    }

    /// Groups entries by `group_by` property and returns a JSON array of groups.
    pub fn grouped_query_book_json(
        &self,
        book_id: String,
        view_id: String,
        group_by: String,
    ) -> Result<String, PinkhaError> {
        let book_uuid = parse_uuid(&book_id)?;
        let view_uuid = parse_uuid(&view_id)?;
        let prop_uuid = parse_uuid(&group_by)?;
        let groups = book_use_cases::grouped_query(&self.uow(), book_uuid, view_uuid, prop_uuid)
            .map_err(PinkhaError::from)?;
        to_json(&groups)
    }

    /// Computes a column aggregate and returns the result as a JSON-encoded
    /// [`PropertyValue`].
    pub fn column_aggregate_book_json(
        &self,
        book_id: String,
        property_id: String,
        aggregate_json: String,
    ) -> Result<String, PinkhaError> {
        let book_uuid = parse_uuid(&book_id)?;
        let prop_uuid = parse_uuid(&property_id)?;
        let aggregate: Aggregate = parse_json(&aggregate_json)?;
        let value =
            book_use_cases::column_aggregate(&self.uow(), book_uuid, prop_uuid, aggregate)
                .map_err(PinkhaError::from)?;
        to_json(&value)
    }

    /// Searches all text-valued properties of a book's entries for `query`
    /// (case-insensitive). Returns matching entries as a JSON array.
    pub fn search_book_entries_json(
        &self,
        book_id: String,
        query: String,
    ) -> Result<String, PinkhaError> {
        validate_string(&query, "query")?;
        let book_uuid = parse_uuid(&book_id)?;
        let entries = book_use_cases::search_entries(&self.uow(), book_uuid, &query)
            .map_err(PinkhaError::from)?;
        to_json(&entries)
    }

    /// Sets (or clears with `None`) the Date column driving every row's
    /// `published_at`. Adopting backfills all rows (+ backing leaves);
    /// clearing resets them to "follow `created_at`". Returns the number
    /// of rows whose publish date changed.
    pub fn set_published_at_source(
        &self,
        book_id: String,
        property_id: Option<String>,
    ) -> Result<u32, PinkhaError> {
        let book_uuid = parse_uuid(&book_id)?;
        let prop_uuid = property_id.as_deref().map(parse_uuid).transpose()?;
        use_cases::set_published_at_source(&self.uow(), book_uuid, prop_uuid)
            .map_err(PinkhaError::from)
    }

    /// Creates a fresh leaf and files it as a new row of `book_id` in a
    /// single call — fills the hidden page-link column and the Title
    /// column automatically when the schema defines them. `values_json`
    /// carries any extra column values (same shape as `add_entry`).
    /// Returns the new leaf's UUID string.
    pub fn create_leaf_in_book(
        &self,
        book_id: String,
        title: String,
        values_json: String,
    ) -> Result<String, PinkhaError> {
        validate_string(&title, "title")?;
        let book_uuid = parse_uuid(&book_id)?;
        let values: HashMap<Uuid, PropertyValue> = parse_json(&values_json)?;
        let (leaf_id, _entry_id) =
            use_cases::create_leaf_in_book(&self.uow(), book_uuid, &title, values)
                .map_err(PinkhaError::from)?;
        Ok(leaf_id.to_string())
    }
}
