use crate::document::Document;
use std::path::PathBuf;

pub fn get_documents_app_dir() -> PathBuf {
    let home = std::env::var("HOME").expect("Pas de HOME");
    PathBuf::from(home)
        .join("iCloud Drive")
        .join("~ Projectground — iCloud")
        .join("Playground")
        .join("Development")
        .join("Rust")
        .join("chaqaq")
        .join("documents")
}

pub fn save_document(doc: &Document) -> Result<(), Box<dyn std::error::Error>> {
    let dir = get_documents_app_dir();
    std::fs::create_dir_all(&dir)?;

    let doc_path = dir.join(format!("{}.json", doc.id));
    let doc_json = serde_json::to_string_pretty(doc)?;
    std::fs::write(doc_path, doc_json)?;

    Ok(())
}

pub fn load_document(id: uuid::Uuid) -> Result<Document, Box<dyn std::error::Error>> {
    let doc_path = get_documents_app_dir().join(format!("{}.json", id));
    let doc_json = std::fs::read_to_string(doc_path)?;
    let doc = serde_json::from_str(&doc_json)?;
    Ok(doc)
}

pub fn get_documents() -> Result<Vec<Document>, Box<dyn std::error::Error>> {
    let dir = get_documents_app_dir();

    let docs = std::fs::read_dir(dir)?
        .map(|entry| -> Result<Document, Box<dyn std::error::Error>> {
            let path = entry?.path();
            let json = std::fs::read_to_string(path)?;
            let doc = serde_json::from_str(&json)?;
            Ok(doc)
        })
        .collect::<Result<Vec<Document>, _>>()?;

    Ok(docs)
}
