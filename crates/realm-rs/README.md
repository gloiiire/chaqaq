# realm-reader

Parser and writer for [Realm](https://github.com/realm/realm-core) binary database files (format version 9).

**Read** an existing `.realm` file without the Realm SDK. **Write** a new `.realm` file from Rust data.

## Reading

```rust
use realm_reader::RealmFile;

let realm = RealmFile::open("/path/to/file.realm")?;

if let Some(table) = realm.table("class_BlockDataModel") {
    println!("{} rows", table.rows.len());
    for row in &table.rows {
        println!("{}", table.get(row, "content").as_str());
    }
}
```

## Writing

```rust
use realm_reader::{RealmBuilder, ColumnType, Value};

let mut builder = RealmBuilder::new();
builder
    .table("class_Note")
    .column("id",   ColumnType::String)
    .column("body", ColumnType::String)
    .column("done", ColumnType::Bool)
    .row(vec![
        Value::String("1".into()),
        Value::String("Buy milk".into()),
        Value::Bool(false),
    ]);

builder.write("/path/to/out.realm")?;
// or: let bytes = builder.to_bytes();
```

## Supported column types

| Realm type   | `Value` variant    | Read | Write |
|-------------|-------------------|:----:|:-----:|
| Int          | `Value::Int`       | ✓    | ✓     |
| Bool         | `Value::Bool`      | ✓    | ✓     |
| String       | `Value::String`    | ✓    | ✓     |
| Data         | `Value::String`    | ✓    | ✓     |
| Float        | `Value::Float`     | ✓    | ✓     |
| Double       | `Value::Float`     | ✓    | ✓     |
| Timestamp    | `Value::Timestamp` | ✓    | ✓     |
| Link         | `Value::Link`      | ✓    | ✓     |

## Features

- Zero dependencies
- Parses Realm v9 format: NodeHeader, Group, spec arrays, full B-tree column traversal
- Writes valid Realm v9 files readable by the Realm SDK and this crate
- Round-trip tested: `RealmBuilder → to_bytes() → RealmFile::from_bytes()`

## License

MIT OR Apache-2.0
