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
fn craft_inspect_col_types() {
    let db = realm_codec::RealmFile::open(CRAFT_REALM).expect("open realm file");
    let table = db.table("class_BlockDataModel").expect("block table");

    println!("BlockDataModel columns ({}):", table.columns.len());
    for (i, (name, ct)) in table.columns.iter().enumerate() {
        println!("  col[{i:02}] {name}: {ct:?}");
    }

    // Verify the blocks (col[11]) and lastSyncedBlockIds (col[12]) columns exist.
    let blocks_col = table.columns.get(11);
    let lsb_col = table.columns.get(12);
    println!("\nblocks col_idx=11: {blocks_col:?}");
    println!("lastSyncedBlockIds col_idx=12: {lsb_col:?}");

    // Verify blocks column is a LinkList and is readable.
    let blocks_idx = table.column_index("blocks").expect("blocks");
    let non_empty = table.rows.iter()
        .filter(|r| !r.get(blocks_idx).as_link_list().is_empty())
        .count();
    println!("\ntotal rows={}, non-empty blocks link lists: {non_empty}", table.rows.len());
    assert!(
        matches!(table.columns[11].1, realm_codec::ColumnType::LinkList),
        "col[11] should be LinkList"
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
    let _bid_col = btable.column_index("id").expect("id");
    let _raw_col = btable.column_index("rawProperties").expect("rawProperties");
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

    // Print ALL DocumentDataModel columns.
    let doc_table = db.table("class_DocumentDataModel").expect("DocumentDataModel");
    println!("DocumentDataModel columns ({}):", doc_table.columns.len());
    for (i, (name, ct)) in doc_table.columns.iter().enumerate() {
        println!("  col[{i:02}] {name}: {ct:?}");
    }

    // Print first 2 rows to see what values look like.
    let id_col   = doc_table.column_index("id").expect("id");
    println!("\nFirst 2 DocumentDataModel rows:");
    for row in doc_table.rows.iter().take(2) {
        for (i, (name, _)) in doc_table.columns.iter().enumerate() {
            let v = row.get(i).as_str();
            if !v.is_empty() { println!("  {name}: {v:?}"); }
        }
        println!("---");
    }

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

    // Count blocks per doc and titleEnabled per doc.
    let lsb_col = btable.column_index("lastSyncedBlockIds").expect("lsb");
    let mut doc_block_counts: std::collections::HashMap<String, (usize, usize)> = Default::default();
    let mut empty_lsb = 0usize;
    for row in &btable.rows {
        let lsb = row.get(lsb_col).as_str().to_lowercase();
        if lsb.is_empty() { empty_lsb += 1; continue; }
        let raw = row.get(raw_col).as_str();
        let is_title = raw.contains("\"titleEnabled\":\"true\"") || raw.contains("\"titleEnabled\":true");
        let entry = doc_block_counts.entry(lsb).or_insert((0, 0));
        entry.0 += 1;
        if is_title { entry.1 += 1; }
    }
    let docs_with_zero_title = doc_block_counts.values().filter(|&&(_, t)| t == 0).count();
    let docs_with_multi_title = doc_block_counts.values().filter(|&&(_, t)| t > 1).count();
    let max_title = doc_block_counts.values().map(|&(_, t)| t).max().unwrap_or(0);

    println!("\nBlocks whose id ∈ doc_ids:        {id_matches_doc}");
    println!("Blocks whose id ∈ rootBlockIds:   {id_matches_root}");
    println!("Blocks with titleEnabled:          {title_enabled}");
    println!("Blocks with empty lastSyncedBlockIds: {empty_lsb}");
    println!("Docs with 0 titleEnabled blocks:  {docs_with_zero_title}");
    println!("Docs with >1 titleEnabled blocks: {docs_with_multi_title}");
    println!("Max titleEnabled blocks in one doc: {max_title}");

    // Show 3 docs with 0 title blocks.
    println!("\nSample docs with 0 titleEnabled blocks:");
    let mut shown = 0;
    for (doc_id, &(total, title_count)) in &doc_block_counts {
        if title_count == 0 {
            println!("  doc={doc_id} total_blocks={total}");
            // Show first block of this doc
            for row in &btable.rows {
                let lsb = row.get(lsb_col).as_str().to_lowercase();
                if &lsb == doc_id {
                    let content_col = btable.column_index("content").unwrap();
                    let type_col    = btable.column_index("type").unwrap();
                    let content = row.get(content_col).as_str();
                    println!("    first block: type={:?} content={:?}",
                        row.get(type_col).as_str(),
                        &content[..content.len().min(80)]);
                    break;
                }
            }
            shown += 1;
            if shown >= 3 { break; }
        }
    }

    // Investigate documentId column — does it point to embedded sub-pages?
    let doc_id_col  = btable.column_index("documentId").expect("documentId");
    let content_col = btable.column_index("content").unwrap();
    let type_col    = btable.column_index("type").unwrap();

    let mut blocks_with_document_id = 0usize;
    let mut document_id_in_doc_ids  = 0usize;
    let mut shown_samples = 0;
    println!("\ndocumentId column investigation:");
    for row in &btable.rows {
        let did = row.get(doc_id_col).as_str().to_lowercase();
        if did.is_empty() { continue; }
        blocks_with_document_id += 1;
        if doc_ids.contains(&did) { document_id_in_doc_ids += 1; }
        if shown_samples < 5 {
            let raw  = row.get(raw_col).as_str();
            let te   = raw.contains("\"titleEnabled\":\"true\"") || raw.contains("\"titleEnabled\":true");
            let lsb  = row.get(lsb_col).as_str().to_lowercase();
            let ct   = row.get(content_col).as_str();
            let same = &lsb == &did;
            println!("  documentId={did:?} lsb={lsb:?} same={same} titleEnabled={te} type={:?} content={:?}",
                row.get(type_col).as_str(),
                &ct[..ct.len().min(60)]);
            shown_samples += 1;
        }
    }
    println!("blocks with non-empty documentId: {blocks_with_document_id}");
    println!("of which documentId ∈ doc_ids: {document_id_in_doc_ids}");

    // How many unique documentId values appear that differ from lastSyncedBlockIds?
    let cross_refs: std::collections::HashSet<String> = btable.rows.iter()
        .filter_map(|r| {
            let did = r.get(doc_id_col).as_str().to_lowercase();
            let lsb = r.get(lsb_col).as_str().to_lowercase();
            if !did.is_empty() && did != lsb { Some(did) } else { None }
        })
        .collect();
    println!("unique documentId values ≠ lastSyncedBlockIds: {}", cross_refs.len());

    // Print full rawProperties of first 10 titleEnabled blocks to look for pageId / sub-page links.
    println!("\nrawProperties of first 10 titleEnabled blocks:");
    let mut shown2 = 0;
    for row in &btable.rows {
        let raw = row.get(raw_col).as_str();
        let te = raw.contains("\"titleEnabled\":\"true\"") || raw.contains("\"titleEnabled\":true");
        if te && shown2 < 10 {
            let lsb = row.get(lsb_col).as_str();
            let ct  = row.get(content_col).as_str();
            println!("  lsb={:?}", &lsb[..lsb.len().min(36)]);
            println!("  content={:?}", &ct[..ct.len().min(60)]);
            println!("  rawProps={:?}", &raw[..raw.len().min(300)]);
            println!("  ---");
            shown2 += 1;
        }
    }
}
