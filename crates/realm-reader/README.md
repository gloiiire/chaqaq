# realm-reader

Read-only parser for [Realm](https://github.com/realm/realm-core) binary database files (format version 9).

Extract tables, column schemas, and rows from a `.realm` file without the Realm SDK — useful for data migration, offline analysis, and building custom import pipelines.

## Features

- Zero dependencies
- Parses Realm v9 format (NodeHeader, Group, spec arrays, B-tree column traversal)
- Typed `Value` enum: Bool, Int, Float, Timestamp, String, Link
- Simple `RealmFile::open(path)` API

## Usage

```rust
use realm_reader::RealmFile;

let realm = RealmFile::open("/path/to/file.realm")?;

for table in realm.tables() {
    println!("Table: {} ({} rows)", table.name, table.rows.len());
    for (col_name, col_type) in &table.columns {
        println!("  {col_name}: {col_type:?}");
    }
}

// Access a specific table
if let Some(blocks) = realm.table("class_BlockDataModel") {
    let content_idx = blocks.column_index("content");
    for row in &blocks.rows {
        if let Some(i) = content_idx {
            println!("{}", row.get(i).as_str());
        }
    }
}
```

## Supported column types

| Realm type   | `Value` variant   |
|-------------|-------------------|
| Int          | `Value::Int`      |
| Bool         | `Value::Bool`     |
| String       | `Value::String`   |
| Data         | `Value::String`   |
| Float        | `Value::Float`    |
| Double       | `Value::Float`    |
| Timestamp    | `Value::Timestamp`|
| Link         | `Value::Link`     |

## License

MIT OR Apache-2.0
