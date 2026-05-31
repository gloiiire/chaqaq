//! Integration test against a real Craft .realm file.
//!
//! Run explicitly: cargo test -p realm-codec -- --ignored craft_

const CRAFT_REALM: &str = concat!(
    "/Users/gloiiire_/Library/Containers/com.lukilabs.lukiapp",
    "/Data/Library/Application Support/com.lukilabs.lukiapp",
    "/LukiMain_0b719b47-f627-6310-39eb-a8ff61a432f7_E2AAB67D-04C7-4F98-964E-B82FFA675833.realm"
);

#[test]
#[ignore = "requires local Craft installation"]
fn craft_block_data_model_loads() {
    let db = realm_codec::RealmFile::open(CRAFT_REALM).expect("open realm file");

    let table = db
        .table("class_BlockDataModel")
        .expect("BlockDataModel table should exist");

    // We confirmed 6763 blocks in the Python investigation.
    let row_count = table.rows.len();
    assert!(
        row_count > 1000,
        "expected thousands of block rows, got {row_count}"
    );

    // Column 0 is the id column — should contain UUID strings.
    let id_col_idx = table.column_index("id").expect("id column");
    let first_id = table.rows[0].get(id_col_idx);
    match first_id {
        realm_codec::Value::String(s) => {
            assert!(!s.is_empty(), "id should be non-empty UUID");
            // UUIDs are 36 chars (with hyphens) or 32 (compact)
            assert!(
                s.len() >= 32 && s.len() <= 36,
                "id looks like a UUID, got len={}: {s:?}",
                s.len()
            );
        }
        other => panic!("expected String id, got {other:?}"),
    }
}

#[test]
#[ignore = "requires local Craft installation"]
fn craft_all_tables_readable() {
    let db = realm_codec::RealmFile::open(CRAFT_REALM).expect("open realm file");
    let tables = db.tables();
    assert!(!tables.is_empty(), "should have at least one table");

    for t in tables {
        println!("  {} ({} rows, {} cols)", t.name, t.rows.len(), t.columns.len());
    }
    assert!(
        tables.iter().any(|t| t.name.contains("BlockDataModel")),
        "BlockDataModel table missing"
    );
}

#[test]
#[ignore = "requires local Craft installation"]
fn craft_content_column_non_empty() {
    let db = realm_codec::RealmFile::open(CRAFT_REALM).expect("open realm file");
    let table = db.table("class_BlockDataModel").expect("table");

    let content_idx = table.column_index("content").expect("content column");
    let non_empty: Vec<&str> = table
        .rows
        .iter()
        .map(|r| r.get(content_idx).as_str())
        .filter(|s| !s.is_empty())
        .take(5)
        .collect();

    println!("First non-empty content values:");
    for s in &non_empty {
        println!("  {:?}", &s[..s.len().min(120)]);
    }

    assert!(
        !non_empty.is_empty(),
        "expected at least some non-empty content strings"
    );
}

#[test]
#[ignore = "requires local Craft installation"]
fn craft_inspect_link_to_doc() {
    let db = realm_codec::RealmFile::open(CRAFT_REALM).expect("open realm file");

    // Collect DocumentDataModel IDs (lowercase).
    let doc_table = db.table("class_DocumentDataModel").expect("DocumentDataModel");
    let did_col   = doc_table.column_index("id").expect("id");
    let doc_ids: std::collections::HashSet<String> = doc_table.rows.iter()
        .map(|r| r.get(did_col).as_str().to_lowercase())
        .filter(|s| !s.is_empty())
        .collect();

    let btable  = db.table("class_BlockDataModel").expect("block table");
    let bid_col  = btable.column_index("id").expect("id");
    let raw_col  = btable.column_index("rawProperties").expect("rawProperties");
    let lsb_col  = btable.column_index("lastSyncedBlockIds").expect("lastSyncedBlockIds");

    // Check if lastSyncedBlockIds values match doc IDs.
    let mut lsb_matches = 0usize;
    let mut unique_lsb: std::collections::HashSet<String> = Default::default();
    for row in &btable.rows {
        let lsb = row.get(lsb_col).as_str().to_lowercase();
        if !lsb.is_empty() { unique_lsb.insert(lsb.clone()); }
        if doc_ids.contains(&lsb) { lsb_matches += 1; }
    }
    println!("unique lastSyncedBlockIds: {}", unique_lsb.len());
    println!("lastSyncedBlockIds ∈ doc_ids: {lsb_matches}");

    // For each block column that is String type, check how many values appear in doc_ids.
    println!("\nCross-ref all string columns against doc_ids:");
    for (ci, (col_name, _)) in btable.columns.iter().enumerate() {
        let mut hits = 0usize;
        for row in &btable.rows {
            let v = row.get(ci).as_str().to_lowercase();
            if doc_ids.contains(&v) { hits += 1; }
        }
        if hits > 0 {
            println!("  [{ci}] {col_name}: {hits} matches");
        }
    }
}

#[test]
#[ignore = "requires local Craft installation"]
fn craft_inspect_document_model() {
    let db = realm_codec::RealmFile::open(CRAFT_REALM).expect("open realm file");

    // Collect all DocumentDataModel IDs and rootBlockIds.
    let doc_table = db.table("class_DocumentDataModel").expect("DocumentDataModel");
    let id_col   = doc_table.column_index("id").expect("id");
    let root_col = doc_table.column_index("rootBlockId").expect("rootBlockId");

    let doc_ids: std::collections::HashSet<String> = doc_table.rows.iter()
        .map(|r| r.get(id_col).as_str().to_lowercase())
        .filter(|s| !s.is_empty())
        .collect();

    let root_block_ids: std::collections::HashSet<String> = doc_table.rows.iter()
        .map(|r| r.get(root_col).as_str().to_lowercase())
        .filter(|s| !s.is_empty())
        .collect();

    println!("DocumentDataModel: {} docs, {} with rootBlockId", doc_ids.len(), root_block_ids.len());
    println!("Sample doc IDs:");
    for id in doc_ids.iter().take(5) { println!("  {id}"); }
    println!("Sample rootBlockIds:");
    for id in root_block_ids.iter().take(5) { println!("  {id}"); }

    // Scan BlockDataModel: check how many block IDs are in doc_ids or root_block_ids.
    let btable = db.table("class_BlockDataModel").expect("block table");
    let bid_col  = btable.column_index("id").expect("id");
    let raw_col  = btable.column_index("rawProperties").expect("rawProperties");

    let mut id_matches_doc   = 0usize;
    let mut id_matches_root  = 0usize;
    let mut title_enabled    = 0usize;

    for row in &btable.rows {
        let bid  = row.get(bid_col).as_str().to_lowercase();
        let raw  = row.get(raw_col).as_str();
        let te   = raw.contains("\"titleEnabled\":\"true\"") || raw.contains("\"titleEnabled\":true");
        if te { title_enabled += 1; }
        if doc_ids.contains(&bid)        { id_matches_doc  += 1; }
        if root_block_ids.contains(&bid) { id_matches_root += 1; }
    }

    println!("\nBlocks whose id ∈ doc_ids:        {id_matches_doc}");
    println!("Blocks whose id ∈ rootBlockIds:   {id_matches_root}");
    println!("Blocks with titleEnabled:          {title_enabled}");

    // Show a few rootBlockId blocks for verification.
    println!("\nFirst 3 blocks matched by rootBlockId:");
    let mut shown = 0;
    for row in &btable.rows {
        let bid = row.get(bid_col).as_str().to_lowercase();
        if root_block_ids.contains(&bid) {
            let content_col = btable.column_index("content").unwrap();
            let type_col    = btable.column_index("type").unwrap();
            println!("  id={bid} type={:?} content={:?}",
                row.get(type_col).as_str(),
                &row.get(content_col).as_str()[..row.get(content_col).as_str().len().min(60)]);
            shown += 1;
            if shown >= 3 { break; }
        }
    }
}
