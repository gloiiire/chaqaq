//! Cross-domain library operations on the [`PinkhaApi`] facade.

use crate::application::use_cases;

use super::types::{
    BlockSearchHitFfi, SuperSearchResultsFfi, book_meta_to_ffi, leaf_meta_to_ffi, shelf_meta_to_ffi,
};
use super::types::{BulkOutcomeFfi, LibrarySnapshotFfi};
use super::validation::{parse_uuids, validate_string};
use super::{PinkhaApi, PinkhaError};

impl PinkhaApi {
    /// Runs every search axis in a single call: leaf titles, block
    /// content (with snippets), book titles and shelf names. The
    /// leaf axis is deduplicated in Rust — a doc matching both title
    /// and content surfaces once in the title hits.
    pub fn super_search(&self, query: String) -> Result<SuperSearchResultsFfi, PinkhaError> {
        validate_string(&query, "query")?;
        let results = use_cases::super_search(&self.uow(), &query).map_err(PinkhaError::from)?;
        Ok(SuperSearchResultsFfi {
            leaves_by_title: results
                .leaves_by_title
                .into_iter()
                .map(leaf_meta_to_ffi)
                .collect(),
            leaves_by_content: results
                .leaves_by_content
                .into_iter()
                .map(|h| BlockSearchHitFfi {
                    doc: leaf_meta_to_ffi(h.doc),
                    block_id: h.block_id.to_string(),
                    snippet: h.snippet,
                })
                .collect(),
            books: results.books.into_iter().map(book_meta_to_ffi).collect(),
            shelves: results.shelves.into_iter().map(shelf_meta_to_ffi).collect(),
        })
    }

    /// Writes a self-contained copy of the whole library to `dest_path`,
    /// returning its size in bytes.
    ///
    /// The caller owns the destination — Swift passes a path inside the
    /// app sandbox, then hands the file to the share sheet. Keeping the
    /// copy in Rust means the export is made from the live connection,
    /// with the write-ahead log folded in; a Swift-side file copy of
    /// `pinkha.db` would ship a database missing its most recent writes.
    ///
    /// One snapshot covers leaves, books and shelves: the three stores
    /// share a single database file.
    pub fn export_library(&self, dest_path: String) -> Result<u64, PinkhaError> {
        validate_string(&dest_path, "dest_path")?;
        self.docs.snapshot_to(&dest_path).map_err(PinkhaError::from)
    }

    /// Écrit un instantané horodaté dans `dir` et n'y conserve que les
    /// `keep` plus récents. Renvoie le chemin écrit.
    ///
    /// Pensé pour être appelé sans intervention de l'utilisateur — au
    /// passage en arrière-plan, par exemple. La perte du 2026-09-02 n'a pas
    /// été causée par une fausse manœuvre : la base a disparu pendant la
    /// nuit. Une protection qui exige une action volontaire n'aurait rien
    /// changé ce jour-là.
    ///
    /// Le nom porte la date en UTC au format trié (`pinkha-20260902-081900.db`)
    /// pour que l'ordre alphabétique soit l'ordre chronologique : la purge
    /// n'a pas à interroger le système de fichiers pour savoir qui est vieux.
    ///
    /// La purge ne touche QUE les fichiers qui portent ce préfixe et cette
    /// extension. Un dossier d'instantanés partagé avec autre chose ne doit
    /// jamais voir disparaître ce qui ne nous appartient pas.
    pub fn snapshot_library(&self, dir: String, keep: u32) -> Result<String, PinkhaError> {
        validate_string(&dir, "dir")?;
        if keep == 0 {
            return Err(PinkhaError::InvalidOperation {
                detail: "keep must be at least 1 — a rotation that keeps nothing is not a backup"
                    .to_string(),
            });
        }
        let horodatage = chrono::Utc::now().format("%Y%m%d-%H%M%S").to_string();
        let base = std::path::Path::new(&dir);
        std::fs::create_dir_all(base).map_err(|e| PinkhaError::Storage {
            detail: e.to_string(),
        })?;
        let cible = base.join(format!("{SNAPSHOT_PREFIX}{horodatage}.db"));
        let chemin = cible.to_string_lossy().into_owned();

        self.docs.snapshot_to(&chemin).map_err(PinkhaError::from)?;
        prune_snapshots(base, keep as usize)?;
        Ok(chemin)
    }

    /// Liste les instantanés présents dans `dir`, du plus récent au plus
    /// ancien. L'interface s'en sert pour montrer « dernière sauvegarde :
    /// … » — une protection silencieuse dont on ne voit rien inquiète plus
    /// qu'elle ne rassure.
    pub fn list_snapshots(&self, dir: String) -> Result<Vec<String>, PinkhaError> {
        validate_string(&dir, "dir")?;
        let mut noms = snapshot_names(std::path::Path::new(&dir))?;
        noms.reverse();
        Ok(noms)
    }

    /// Everything the library screen renders, in a single call.
    ///
    /// `PinkhaStore.load()` used to issue four separate FFI calls, and it
    /// runs after every mutation from roughly twenty call sites. Fetching
    /// the four lists together also keeps them consistent with each other:
    /// as four calls, a write landing between them could yield a shelf list
    /// that disagrees with the leaves said to live in it.
    ///
    /// Root-ness comes from `list_root_leaves`, deliberately — it is the one
    /// definition of "at the root", and adding a second spelling here is
    /// exactly the bug that once made leaves vanish when their shelf was
    /// discarded.
    pub fn library_snapshot(&self) -> Result<LibrarySnapshotFfi, PinkhaError> {
        let uow = self.uow();
        Ok(LibrarySnapshotFfi {
            root_leaves: use_cases::list_root_leaves(&uow)
                .map_err(PinkhaError::from)?
                .into_iter()
                .map(leaf_meta_to_ffi)
                .collect(),
            all_leaves: use_cases::list_leaves(&uow)
                .map_err(PinkhaError::from)?
                .into_iter()
                .map(leaf_meta_to_ffi)
                .collect(),
            books: crate::application::book_use_cases::list_books(&uow)
                .map_err(PinkhaError::from)?
                .into_iter()
                .map(book_meta_to_ffi)
                .collect(),
            shelves: crate::application::shelf_use_cases::list_shelves(&uow)
                .map_err(PinkhaError::from)?
                .into_iter()
                .map(shelf_meta_to_ffi)
                .collect(),
        })
    }

    /// Permanently purges every soft-deleted leaf, book and shelf
    /// in one bulk operation. Returns the total number of items removed.
    pub fn empty_trash(&self) -> Result<u32, PinkhaError> {
        use_cases::empty_trash(&self.uow()).map_err(PinkhaError::from)
    }

    /// Soft-deletes a mixed selection in a single call.
    ///
    /// Swift used to loop over the selection, paying one FFI crossing and
    /// one full library reload per item for what the user performed as a
    /// single tap. Ids that no longer exist are counted as `skipped`
    /// rather than failing the batch — a selection is a snapshot taken
    /// before the confirmation dialog, so it can go stale legitimately.
    pub fn delete_items(
        &self,
        leaf_ids: Vec<String>,
        book_ids: Vec<String>,
        shelf_ids: Vec<String>,
    ) -> Result<BulkOutcomeFfi, PinkhaError> {
        let (l, b, s) = (
            parse_uuids(leaf_ids)?,
            parse_uuids(book_ids)?,
            parse_uuids(shelf_ids)?,
        );
        let out = use_cases::delete_items(&self.uow(), &l, &b, &s).map_err(PinkhaError::from)?;
        Ok(BulkOutcomeFfi {
            affected: out.affected,
            skipped: out.skipped,
        })
    }

    /// Restores a mixed selection out of Compost. See [`Self::delete_items`].
    pub fn restore_items(
        &self,
        leaf_ids: Vec<String>,
        book_ids: Vec<String>,
        shelf_ids: Vec<String>,
    ) -> Result<BulkOutcomeFfi, PinkhaError> {
        let (l, b, s) = (
            parse_uuids(leaf_ids)?,
            parse_uuids(book_ids)?,
            parse_uuids(shelf_ids)?,
        );
        let out = use_cases::restore_items(&self.uow(), &l, &b, &s).map_err(PinkhaError::from)?;
        Ok(BulkOutcomeFfi {
            affected: out.affected,
            skipped: out.skipped,
        })
    }

    /// Permanently removes a mixed selection. See [`Self::delete_items`].
    pub fn purge_items(
        &self,
        leaf_ids: Vec<String>,
        book_ids: Vec<String>,
        shelf_ids: Vec<String>,
    ) -> Result<BulkOutcomeFfi, PinkhaError> {
        let (l, b, s) = (
            parse_uuids(leaf_ids)?,
            parse_uuids(book_ids)?,
            parse_uuids(shelf_ids)?,
        );
        let out = use_cases::purge_items(&self.uow(), &l, &b, &s).map_err(PinkhaError::from)?;
        Ok(BulkOutcomeFfi {
            affected: out.affected,
            skipped: out.skipped,
        })
    }
}

/// Préfixe commun à tous les instantanés produits par `snapshot_library`.
/// La purge s'en sert pour ne jamais toucher un fichier étranger.
const SNAPSHOT_PREFIX: &str = "pinkha-";

/// Noms des instantanés de `dir`, triés par ordre croissant — donc du plus
/// ancien au plus récent, l'horodatage étant en tête du nom.
fn snapshot_names(dir: &std::path::Path) -> Result<Vec<String>, PinkhaError> {
    if !dir.exists() {
        return Ok(Vec::new());
    }
    let mut noms: Vec<String> = std::fs::read_dir(dir)
        .map_err(|e| PinkhaError::Storage {
            detail: e.to_string(),
        })?
        .filter_map(|entree| entree.ok())
        .filter_map(|entree| entree.file_name().into_string().ok())
        .filter(|nom| nom.starts_with(SNAPSHOT_PREFIX) && nom.ends_with(".db"))
        .collect();
    noms.sort();
    Ok(noms)
}

/// Ne conserve que les `keep` instantanés les plus récents de `dir`.
fn prune_snapshots(dir: &std::path::Path, keep: usize) -> Result<(), PinkhaError> {
    let noms = snapshot_names(dir)?;
    if noms.len() <= keep {
        return Ok(());
    }
    for nom in &noms[..noms.len() - keep] {
        // Un échec de suppression ne doit pas invalider un instantané qui
        // vient d'être écrit avec succès : le fichier neuf est ce qui
        // protège l'utilisateur, le ménage peut attendre le prochain tour.
        let _ = std::fs::remove_file(dir.join(nom));
    }
    Ok(())
}
