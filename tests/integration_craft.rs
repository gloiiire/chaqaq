// ── Craft extractor — integration tests ───────────────────────────────────────
//
// The `craft_full_run` test is `#[ignore]` because it requires a local Craft
// installation with the specific realm file path hardcoded below.
//
// Run it explicitly:
//   cargo test -- --ignored craft_full_run --nocapture

use pinkha::extractors::craft::{CraftConfig, CraftExtractor};
use pinkha::extractors::traits::Extractor;
use pinkha::infrastructure::sqlite_book_store::SqliteBookStore;
use pinkha::infrastructure::sqlite_leaf_store::SqliteLeafStore;
use pinkha::infrastructure::sqlite_shelf_store::SqliteShelfStore;

const CRAFT_REALM: &str = concat!(
    "/Users/gloiiire_/Library/Containers/com.lukilabs.lukiapp",
    "/Data/Library/Application Support/com.lukilabs.lukiapp",
    "/LukiMain_0b719b47-f627-6310-39eb-a8ff61a432f7_E2AAB67D-04C7-4F98-964E-B82FFA675833.realm"
);

#[tokio::test]
#[ignore = "requires local Craft installation"]
async fn craft_full_run() {
    let leaf_store = SqliteLeafStore::in_memory().expect("doc store");
    let book_store = SqliteBookStore::in_memory().expect("db store");
    let shelf_store = SqliteShelfStore::in_memory().expect("shelf store");

    let extractor = CraftExtractor::new();
    let config = CraftConfig {
        db_path: CRAFT_REALM.to_string(),
    };

    let result = extractor
        .run(config, &leaf_store, &book_store, &shelf_store)
        .await
        .expect("extractor should succeed");

    println!("Import result:");
    println!("  app       = {}", result.app);
    println!("  leaves = {}", result.leaves);
    println!("  blocks    = {}", result.blocks);
    println!("  skipped   = {}", result.skipped);

    // The Craft realm file has ~2498 title-enabled blocks (pages).
    assert!(
        result.leaves > 100,
        "expected many leaves, got {}",
        result.leaves
    );
    assert!(
        result.blocks > 1000,
        "expected many blocks, got {}",
        result.blocks
    );
    assert_eq!(result.app, "Craft");
    assert_eq!(result.book_id, None);

    // Verify a sample of imported leaves via the store.
    use pinkha::application::repository::LeafRepository;
    let docs = leaf_store.list().expect("list");
    println!("  first 3 doc titles:");
    for d in docs.iter().take(3) {
        let title: String = d.title.iter().map(|s| s.content.as_str()).collect();
        println!("    {title:?}");
    }
    assert_eq!(docs.len(), result.leaves);
}
