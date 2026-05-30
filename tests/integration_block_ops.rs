use chaqaq::application::error::ChaqaqError;
use chaqaq::application::use_cases::{
    add_block, add_child_block, create_document, update_block, update_document_cover,
    update_document_title, get_document, reorder_blocks, save_edited_block,
    delete_block,
};
use chaqaq::domain::document::{BlockContent, InlineText};
use chaqaq::domain::editor::EditorState;
use chaqaq::domain::rich_text::RichText;
use chaqaq::infrastructure::json_store::JsonStore;
use uuid::Uuid;

fn store_temp() -> JsonStore {
    let dir = std::env::temp_dir().join(format!("chaqaq_blocs_{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    JsonStore::new(dir)
}

fn inlines(s: &str) -> Vec<InlineText> {
    vec![InlineText {
        content: s.to_string(),
        styles: vec![],
    }]
}

fn etat_depuis(s: &str) -> EditorState {
    let il = inlines(s);
    EditorState::nouveau(RichText::from(&il))
}

// ── Bridge EditorState → Block ────────────────────────────────────────────────

#[test]
fn test_save_edited_block_text() {
    let store = store_temp();
    let doc = create_document(&store, "Doc").unwrap();
    let doc = add_block(&store, doc.id, BlockContent::Text(inlines("initial"))).unwrap();
    let block_id = doc.blocks[0].id;

    save_edited_block(&store, doc.id, block_id, &etat_depuis("modifié")).unwrap();

    let recharge = get_document(&store, doc.id).unwrap();
    assert!(
        matches!(&recharge.blocks[0].content, BlockContent::Text(t) if t[0].content == "modifié")
    );
}

#[test]
fn test_save_edited_block_heading() {
    let store = store_temp();
    let doc = create_document(&store, "Doc").unwrap();
    let doc = add_block(
        &store,
        doc.id,
        BlockContent::Heading {
            text: inlines("title initial"),
            level: 1,
        },
    )
    .unwrap();
    let block_id = doc.blocks[0].id;

    save_edited_block(&store, doc.id, block_id, &etat_depuis("title modifié")).unwrap();

    let recharge = get_document(&store, doc.id).unwrap();
    assert!(matches!(
        &recharge.blocks[0].content,
        BlockContent::Heading { text: t, level: 1 } if t[0].content == "title modifié"
    ));
}

#[test]
fn test_sauvegarder_bloc_non_textuel_retourne_erreur() {
    let store = store_temp();
    let doc = create_document(&store, "Doc").unwrap();
    let doc = add_block(&store, doc.id, BlockContent::Divider).unwrap();
    let block_id = doc.blocks[0].id;

    let result = save_edited_block(&store, doc.id, block_id, &etat_depuis("x"));
    assert!(matches!(result, Err(ChaqaqError::InvalidOperation(_))));
}

// ── Gestion des blocs ─────────────────────────────────────────────────────────

#[test]
fn test_update_block_toggle_todo() {
    let store = store_temp();
    let doc = create_document(&store, "Tâches").unwrap();
    let doc = add_block(
        &store,
        doc.id,
        BlockContent::Todo {
            text: inlines("faire la vaisselle"),
            done: false,
        },
    )
    .unwrap();
    let block_id = doc.blocks[0].id;

    update_block(
        &store,
        doc.id,
        block_id,
        BlockContent::Todo {
            text: inlines("faire la vaisselle"),
            done: true,
        },
    )
    .unwrap();

    let recharge = get_document(&store, doc.id).unwrap();
    assert!(matches!(
        &recharge.blocks[0].content,
        BlockContent::Todo { done: true, .. }
    ));
}

#[test]
fn test_update_block_inexistant_retourne_non_trouve() {
    let store = store_temp();
    let doc = create_document(&store, "Doc").unwrap();
    let faux_id = Uuid::new_v4();

    let result = update_block(&store, doc.id, faux_id, BlockContent::Divider);
    assert!(matches!(result, Err(ChaqaqError::NotFound(_))));
}

#[test]
fn test_delete_block() {
    let store = store_temp();
    let doc = create_document(&store, "Doc").unwrap();
    let doc = add_block(&store, doc.id, BlockContent::Text(inlines("A"))).unwrap();
    let doc = add_block(&store, doc.id, BlockContent::Text(inlines("B"))).unwrap();
    let id_a = doc.blocks[0].id;

    delete_block(&store, doc.id, id_a).unwrap();

    let recharge = get_document(&store, doc.id).unwrap();
    assert_eq!(recharge.blocks.len(), 1);
    assert!(matches!(&recharge.blocks[0].content, BlockContent::Text(t) if t[0].content == "B"));
}

#[test]
fn test_delete_block_inexistant_retourne_non_trouve() {
    let store = store_temp();
    let doc = create_document(&store, "Doc").unwrap();
    let result = delete_block(&store, doc.id, Uuid::new_v4());
    assert!(matches!(result, Err(ChaqaqError::NotFound(_))));
}

#[test]
fn test_reorder_blocks() {
    let store = store_temp();
    let doc = create_document(&store, "Doc").unwrap();
    let doc = add_block(&store, doc.id, BlockContent::Text(inlines("A"))).unwrap();
    let doc = add_block(&store, doc.id, BlockContent::Text(inlines("B"))).unwrap();
    let doc = add_block(&store, doc.id, BlockContent::Text(inlines("C"))).unwrap();
    let id_a = doc.blocks[0].id;
    let id_b = doc.blocks[1].id;
    let id_c = doc.blocks[2].id;

    reorder_blocks(&store, doc.id, vec![id_c, id_a, id_b]).unwrap();

    let recharge = get_document(&store, doc.id).unwrap();
    assert_eq!(recharge.blocks[0].id, id_c);
    assert_eq!(recharge.blocks[1].id, id_a);
    assert_eq!(recharge.blocks[2].id, id_b);
}

#[test]
fn test_reorder_blocks_partiels_conserve_le_reste() {
    let store = store_temp();
    let doc = create_document(&store, "Doc").unwrap();
    let doc = add_block(&store, doc.id, BlockContent::Text(inlines("A"))).unwrap();
    let doc = add_block(&store, doc.id, BlockContent::Text(inlines("B"))).unwrap();
    let doc = add_block(&store, doc.id, BlockContent::Text(inlines("C"))).unwrap();
    let id_a = doc.blocks[0].id;
    let id_c = doc.blocks[2].id;

    // Réordonne seulement A et C ; B est non mentionné → va en fin
    reorder_blocks(&store, doc.id, vec![id_c, id_a]).unwrap();

    let recharge = get_document(&store, doc.id).unwrap();
    assert_eq!(recharge.blocks.len(), 3);
    assert_eq!(recharge.blocks[0].id, id_c);
    assert_eq!(recharge.blocks[1].id, id_a);
}

// ── Métadonnées document ──────────────────────────────────────────────────────

#[test]
fn test_update_document_title() {
    let store = store_temp();
    let doc = create_document(&store, "Titre initial").unwrap();

    update_document_title(&store, doc.id, "Nouveau title").unwrap();

    let recharge = get_document(&store, doc.id).unwrap();
    assert_eq!(recharge.title[0].content, "Nouveau title");
}

#[test]
fn test_update_document_cover() {
    let store = store_temp();
    let doc = create_document(&store, "Doc").unwrap();
    assert!(doc.cover.is_none());

    update_document_cover(&store, doc.id, Some("🌄".to_string())).unwrap();
    let recharge = get_document(&store, doc.id).unwrap();
    assert_eq!(recharge.cover, Some("🌄".to_string()));

    update_document_cover(&store, doc.id, None).unwrap();
    let recharge = get_document(&store, doc.id).unwrap();
    assert!(recharge.cover.is_none());
}

// ── Blocs imbriqués ───────────────────────────────────────────────────────────

#[test]
fn test_add_child_block() {
    let store = store_temp();
    let doc = create_document(&store, "Doc").unwrap();
    let doc = add_block(&store, doc.id, BlockContent::Text(inlines("parent"))).unwrap();
    let parent_id = doc.blocks[0].id;

    let enfant = add_child_block(
        &store,
        doc.id,
        parent_id,
        BlockContent::Text(inlines("enfant")),
    )
    .unwrap();

    let recharge = get_document(&store, doc.id).unwrap();
    assert_eq!(recharge.blocks[0].children.len(), 1);
    assert_eq!(recharge.blocks[0].children[0].id, enfant.id);
}

#[test]
fn test_ajouter_plusieurs_enfants() {
    let store = store_temp();
    let doc = create_document(&store, "Doc").unwrap();
    let doc = add_block(&store, doc.id, BlockContent::Text(inlines("parent"))).unwrap();
    let parent_id = doc.blocks[0].id;

    add_child_block(
        &store,
        doc.id,
        parent_id,
        BlockContent::Text(inlines("enfant 1")),
    )
    .unwrap();
    add_child_block(
        &store,
        doc.id,
        parent_id,
        BlockContent::Text(inlines("enfant 2")),
    )
    .unwrap();

    let recharge = get_document(&store, doc.id).unwrap();
    assert_eq!(recharge.blocks[0].children.len(), 2);
}

#[test]
fn test_add_child_block_parent_inexistant() {
    let store = store_temp();
    let doc = create_document(&store, "Doc").unwrap();

    let result = add_child_block(
        &store,
        doc.id,
        Uuid::new_v4(),
        BlockContent::Text(inlines("orphelin")),
    );
    assert!(matches!(result, Err(ChaqaqError::NotFound(_))));
}

#[test]
fn test_delete_block_enfant_recursif() {
    let store = store_temp();
    let doc = create_document(&store, "Doc").unwrap();
    let doc = add_block(&store, doc.id, BlockContent::Text(inlines("parent"))).unwrap();
    let parent_id = doc.blocks[0].id;

    let enfant = add_child_block(
        &store,
        doc.id,
        parent_id,
        BlockContent::Text(inlines("enfant")),
    )
    .unwrap();

    delete_block(&store, doc.id, enfant.id).unwrap();

    let recharge = get_document(&store, doc.id).unwrap();
    assert!(recharge.blocks[0].children.is_empty());
}
