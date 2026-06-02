use crate::application::error::PinkhaError;
use crate::application::repository::DocumentRepository;
use crate::domain::document::{Block, BlockContent, DocumentMeta};

/// Case-insensitive search across document titles.
pub fn search_documents(
    repo: &dyn DocumentRepository,
    query: &str,
) -> Result<Vec<DocumentMeta>, PinkhaError> {
    let q = query.to_lowercase();
    Ok(repo
        .list()?
        .into_iter()
        .filter(|m| {
            m.title
                .iter()
                .any(|t| t.content.to_lowercase().contains(&q))
        })
        .collect())
}

/// Case-insensitive full-text search across the block content of all documents.
///
/// Returns the metadata of documents that contain at least one matching block.
pub fn search_in_blocks(
    repo: &dyn DocumentRepository,
    query: &str,
) -> Result<Vec<DocumentMeta>, PinkhaError> {
    let q = query.to_lowercase();
    let metas = repo.list()?;
    let mut results = Vec::new();
    for meta in metas {
        let doc = repo.load(meta.id)?;
        if blocks_contain(&doc.blocks, &q) {
            results.push(meta);
        }
    }
    Ok(results)
}

// ── Internal helpers ──────────────────────────────────────────────────────────

fn blocks_contain(blocks: &[Block], query: &str) -> bool {
    blocks.iter().any(|b| block_contains(b, query))
}

fn block_contains(block: &Block, query: &str) -> bool {
    let matches_text = match &block.content {
        BlockContent::Text(inlines)
        | BlockContent::Heading { text: inlines, .. }
        | BlockContent::Quote { text: inlines, .. }
        | BlockContent::Todo { text: inlines, .. }
        | BlockContent::BulletedListItem(inlines)
        | BlockContent::NumberedListItem(inlines) => inlines
            .iter()
            .any(|i| i.content.to_lowercase().contains(query)),
        BlockContent::Code { text, .. } => text.to_lowercase().contains(query),
        _ => false,
    };
    matches_text || blocks_contain(&block.children, query)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::application::error::PinkhaError;
    use crate::domain::document::{Block, BlockContent, Document, DocumentMeta, InlineText};
    use std::cell::RefCell;
    use std::collections::HashMap;
    use uuid::Uuid;

    struct MockRepo {
        docs: RefCell<HashMap<Uuid, Document>>,
    }

    impl MockRepo {
        fn new() -> Self {
            Self {
                docs: RefCell::new(HashMap::new()),
            }
        }
    }

    impl crate::application::repository::DocumentRepository for MockRepo {
        fn save(&self, doc: &Document) -> Result<(), PinkhaError> {
            self.docs.borrow_mut().insert(doc.id, doc.clone());
            Ok(())
        }
        fn load(&self, id: Uuid) -> Result<Document, PinkhaError> {
            self.docs
                .borrow()
                .get(&id)
                .cloned()
                .ok_or(PinkhaError::NotFound(id))
        }
        fn list(&self) -> Result<Vec<DocumentMeta>, PinkhaError> {
            Ok(self
                .docs
                .borrow()
                .values()
                .map(DocumentMeta::from)
                .collect())
        }
        fn delete(&self, id: Uuid) -> Result<(), PinkhaError> {
            self.docs
                .borrow_mut()
                .remove(&id)
                .map(|_| ())
                .ok_or(PinkhaError::NotFound(id))
        }
        fn move_to_folder(
            &self,
            _doc_id: Uuid,
            _folder_id: Option<Uuid>,
        ) -> Result<(), PinkhaError> {
            Ok(())
        }
        fn list_by_folder(
            &self,
            _folder_id: Option<Uuid>,
        ) -> Result<Vec<DocumentMeta>, PinkhaError> {
            self.list()
        }
    }

    fn inline(s: &str) -> Vec<InlineText> {
        vec![InlineText {
            content: s.to_string(),
            styles: vec![],
        }]
    }

    fn text_block(s: &str) -> Block {
        Block::new(BlockContent::Text(inline(s)))
    }

    fn doc_with_blocks(title: &str, blocks: Vec<Block>) -> Document {
        let mut doc = Document::new(inline(title));
        doc.blocks = blocks;
        doc
    }

    #[test]
    fn test_search_in_blocks_trouve() {
        let repo = MockRepo::new();
        let doc = doc_with_blocks("Doc", vec![text_block("Rust est génial")]);
        repo.save(&doc).unwrap();

        let results = search_in_blocks(&repo, "rust").unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].id, doc.id);
    }

    #[test]
    fn test_search_in_blocks_pas_de_resultat() {
        let repo = MockRepo::new();
        let doc = doc_with_blocks("Doc", vec![text_block("Bonjour monde")]);
        repo.save(&doc).unwrap();

        let results = search_in_blocks(&repo, "flutter").unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn test_search_in_blocks_enfants() {
        let repo = MockRepo::new();
        let mut parent = text_block("parent");
        parent
            .children
            .push(text_block("texte caché en profondeur"));
        let doc = doc_with_blocks("Doc", vec![parent]);
        repo.save(&doc).unwrap();

        let results = search_in_blocks(&repo, "profondeur").unwrap();
        assert_eq!(results.len(), 1);
    }
}
