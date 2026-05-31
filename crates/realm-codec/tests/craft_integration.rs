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
fn craft_inspect_document_model() {
    let db = realm_codec::RealmFile::open(CRAFT_REALM).expect("open realm file");
    let table = db.table("class_DocumentDataModel").expect("table");

    println!("DocumentDataModel columns: {:?}", table.columns.iter().map(|(n,t)| format!("{n}:{t:?}")).collect::<Vec<_>>());
    
    for (i, row) in table.rows.iter().take(5).enumerate() {
        println!("\nDoc[{i}]:");
        for (ci, (col_name, _)) in table.columns.iter().enumerate() {
            let val = row.get(ci);
            if !val.is_null() {
                println!("  {col_name} = {val:?}");
            }
        }
    }
    
    // Also inspect BlockDataModel for first few blocks
    let btable = db.table("class_BlockDataModel").expect("block table");
    println!("\nBlockDataModel columns ({}):", btable.columns.len());
    for (n, t) in &btable.columns {
        println!("  {n}: {t:?}");
    }
    
    println!("\nFirst 5 blocks:");
    for (i, row) in btable.rows.iter().take(5).enumerate() {
        println!("\nBlock[{i}]:");
        for (ci, (col_name, _)) in btable.columns.iter().enumerate() {
            let val = row.get(ci);
            if !val.is_null() {
                let display = match val {
                    realm_codec::Value::String(s) if s.len() > 80 => format!("String({:?}...)", &s[..80]),
                    _ => format!("{val:?}"),
                };
                println!("  {col_name} = {display}");
            }
        }
    }
}
