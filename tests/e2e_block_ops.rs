use pinkha::application::use_cases::{
    add_block, add_child_block, create_document, delete_block, get_document, reorder_blocks,
    save_edited_block, set_block_color, update_block, update_document_cover, update_document_title,
};
use pinkha::domain::document::{BlockContent, InlineStyle, InlineText};
use pinkha::domain::editor::EditorState;
use pinkha::domain::rich_text::RichText;
use pinkha::infrastructure::json_store::JsonStore;
use uuid::Uuid;

fn store_temp() -> JsonStore {
    let dir = std::env::temp_dir().join(format!("pinkha_e2e_blocs_{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    JsonStore::new(dir)
}

fn inlines(s: &str) -> Vec<InlineText> {
    vec![InlineText {
        content: s.to_string(),
        styles: vec![],
    }]
}

/// Full flow: create, edit, toggle, delete, reload.
#[test]
fn test_flux_edition_complete() {
    let store = store_temp();

    // Create a document with several block types
    let doc = create_document(&store, "Ma page").unwrap();
    let doc = add_block(
        &store,
        doc.id,
        BlockContent::Heading {
            text: inlines("Introduction"),
            level: 1,
        },
    )
    .unwrap();
    let doc = add_block(
        &store,
        doc.id,
        BlockContent::Text(inlines("Premier paragraphe")),
    )
    .unwrap();
    let doc = add_block(
        &store,
        doc.id,
        BlockContent::Todo {
            text: inlines("Relire"),
            done: false,
        },
    )
    .unwrap();

    let id_heading = doc.blocks[0].id;
    let id_para = doc.blocks[1].id;
    let id_todo = doc.blocks[2].id;

    // Edit the heading via EditorState
    let rt = RichText::from(&inlines("Introduction révisée"));
    save_edited_block(&store, doc.id, id_heading, &EditorState::new(rt)).unwrap();

    // Edit the paragraph with bold style
    let inlines_gras = vec![InlineText {
        content: "Texte en gras".to_string(),
        styles: vec![InlineStyle::Bold],
    }];
    let rt = RichText::from(&inlines_gras);
    save_edited_block(&store, doc.id, id_para, &EditorState::new(rt)).unwrap();

    // Toggle the todo
    update_block(
        &store,
        doc.id,
        id_todo,
        BlockContent::Todo {
            text: inlines("Relire"),
            done: true,
        },
    )
    .unwrap();

    // Reload and verify everything
    let recharge = get_document(&store, doc.id).unwrap();
    assert_eq!(recharge.blocks.len(), 3);

    assert!(matches!(
        &recharge.blocks[0].content,
        BlockContent::Heading { text: t, level: 1 } if t[0].content == "Introduction révisée"
    ));
    assert!(matches!(
        &recharge.blocks[1].content,
        BlockContent::Text(t) if t[0].styles == vec![InlineStyle::Bold]
    ));
    assert!(matches!(
        &recharge.blocks[2].content,
        BlockContent::Todo { done: true, .. }
    ));
}

/// Create, reorder, delete — verify persistence at each step.
#[test]
fn test_flux_reordonnement_et_suppression() {
    let store = store_temp();

    let doc = create_document(&store, "Flux").unwrap();
    let doc = add_block(&store, doc.id, BlockContent::Text(inlines("Alpha"))).unwrap();
    let doc = add_block(&store, doc.id, BlockContent::Text(inlines("Beta"))).unwrap();
    let doc = add_block(&store, doc.id, BlockContent::Text(inlines("Gamma"))).unwrap();
    let doc = add_block(&store, doc.id, BlockContent::Divider).unwrap();

    let id_alpha = doc.blocks[0].id;
    let id_beta = doc.blocks[1].id;
    let id_gamma = doc.blocks[2].id;
    let id_div = doc.blocks[3].id;

    // Reorder: Divider, Gamma, Alpha, Beta
    reorder_blocks(&store, doc.id, vec![id_div, id_gamma, id_alpha, id_beta]).unwrap();

    let apres_reorder = get_document(&store, doc.id).unwrap();
    assert_eq!(apres_reorder.blocks[0].id, id_div);
    assert_eq!(apres_reorder.blocks[1].id, id_gamma);

    // Delete Divider
    delete_block(&store, doc.id, id_div).unwrap();

    let final_doc = get_document(&store, doc.id).unwrap();
    assert_eq!(final_doc.blocks.len(), 3);
    assert_eq!(final_doc.blocks[0].id, id_gamma);
}

/// Verify that EditorState preserves styles during a block save.
#[test]
fn test_styles_preserves_apres_sauvegarde_bloc() {
    let store = store_temp();

    let inlines_styled = vec![
        InlineText {
            content: "normal ".to_string(),
            styles: vec![],
        },
        InlineText {
            content: "italique".to_string(),
            styles: vec![InlineStyle::Italic],
        },
    ];
    let doc = create_document(&store, "Style").unwrap();
    let doc = add_block(&store, doc.id, BlockContent::Text(inlines_styled.clone())).unwrap();
    let block_id = doc.blocks[0].id;

    // Save via EditorState (round-trip RichText → Vec<InlineText>)
    let rt = RichText::from(&inlines_styled);
    save_edited_block(&store, doc.id, block_id, &EditorState::new(rt)).unwrap();

    let recharge = get_document(&store, doc.id).unwrap();
    if let BlockContent::Text(t) = &recharge.blocks[0].content {
        let styles_concat: Vec<&InlineStyle> = t.iter().flat_map(|i| &i.styles).collect();
        assert!(styles_concat.contains(&&InlineStyle::Italic));
    } else {
        panic!("type de bloc inattendu");
    }
}

/// Page with editable title, cover, and nested blocks — Notion page scenario.
#[test]
fn test_flux_page_complete() {
    let store = store_temp();

    let doc = create_document(&store, "Brouillon").unwrap();

    // Rename and add a cover
    update_document_title(&store, doc.id, "Mon projet 2025").unwrap();
    update_document_cover(&store, doc.id, Some("🚀".to_string())).unwrap();

    // Structure: Heading with nested paragraphs
    let doc = add_block(
        &store,
        doc.id,
        BlockContent::Heading {
            text: inlines("Objectifs"),
            level: 1,
        },
    )
    .unwrap();
    let heading_id = doc.blocks[0].id;

    add_child_block(
        &store,
        doc.id,
        heading_id,
        BlockContent::Todo {
            text: inlines("Finir le backend"),
            done: true,
        },
    )
    .unwrap();
    add_child_block(
        &store,
        doc.id,
        heading_id,
        BlockContent::Todo {
            text: inlines("Attaquer Flutter"),
            done: false,
        },
    )
    .unwrap();

    // Reload and verify everything
    let page = get_document(&store, doc.id).unwrap();
    assert_eq!(page.title[0].content, "Mon projet 2025");
    assert_eq!(page.cover, Some("🚀".to_string()));
    assert_eq!(page.blocks[0].children.len(), 2);
    assert!(matches!(
        &page.blocks[0].children[0].content,
        BlockContent::Todo { done: true, .. }
    ));
    assert!(matches!(
        &page.blocks[0].children[1].content,
        BlockContent::Todo { done: false, .. }
    ));
}

/// Block color: set → reload from disk → still there → clear → reload → gone.
/// Exercises the JsonStore round-trip on the new `Block.color` field.
#[test]
fn test_block_color_persists_round_trip() {
    let store = store_temp();
    let doc = create_document(&store, "Color test").unwrap();
    let block_id = add_block(&store, doc.id, BlockContent::Text(inlines("hello"))).unwrap();
    let block_uuid = block_id.blocks.last().unwrap().id;

    // No color by default.
    let reloaded = get_document(&store, doc.id).unwrap();
    assert!(reloaded.blocks[0].color.is_none());

    // Apply a color and verify it survives a reload from disk.
    set_block_color(&store, doc.id, block_uuid, Some("purple".into())).unwrap();
    let reloaded = get_document(&store, doc.id).unwrap();
    assert_eq!(reloaded.blocks[0].color.as_deref(), Some("purple"));

    // Clear the color and verify it disappears.
    set_block_color(&store, doc.id, block_uuid, None).unwrap();
    let reloaded = get_document(&store, doc.id).unwrap();
    assert!(reloaded.blocks[0].color.is_none());
}
