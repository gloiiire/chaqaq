use pinkha::application::use_cases::{
    add_block, add_child_block, create_document, update_block, update_document_cover,
    update_document_title, get_document, reorder_blocks, save_edited_block,
    delete_block,
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

/// Flux complet : créer, éditer, toggle, supprimer, recharger.
#[test]
fn test_flux_edition_complete() {
    let store = store_temp();

    // Crée un document avec plusieurs types de blocs
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

    // Édite le heading via EditorState
    let rt = RichText::from(&inlines("Introduction révisée"));
    save_edited_block(&store, doc.id, id_heading, &EditorState::nouveau(rt)).unwrap();

    // Édite le paragraphe avec un style gras
    let inlines_gras = vec![InlineText {
        content: "Texte en gras".to_string(),
        styles: vec![InlineStyle::Bold],
    }];
    let rt = RichText::from(&inlines_gras);
    save_edited_block(&store, doc.id, id_para, &EditorState::nouveau(rt)).unwrap();

    // Toggle la todo
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

    // Recharge et vérifie tout
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

/// Créer, réordonner, supprimer — vérifier la persistance à chaque étape.
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

    // Réordonne : Divider, Gamma, Alpha, Beta
    reorder_blocks(&store, doc.id, vec![id_div, id_gamma, id_alpha, id_beta]).unwrap();

    let apres_reorder = get_document(&store, doc.id).unwrap();
    assert_eq!(apres_reorder.blocks[0].id, id_div);
    assert_eq!(apres_reorder.blocks[1].id, id_gamma);

    // Supprime Divider
    delete_block(&store, doc.id, id_div).unwrap();

    let final_doc = get_document(&store, doc.id).unwrap();
    assert_eq!(final_doc.blocks.len(), 3);
    assert_eq!(final_doc.blocks[0].id, id_gamma);
}

/// Vérifie que EditorState préserve les styles lors d'une sauvegarde.
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

    // Sauvegarde via EditorState (round-trip RichText → Vec<InlineText>)
    let rt = RichText::from(&inlines_styled);
    save_edited_block(&store, doc.id, block_id, &EditorState::nouveau(rt)).unwrap();

    let recharge = get_document(&store, doc.id).unwrap();
    if let BlockContent::Text(t) = &recharge.blocks[0].content {
        let styles_concat: Vec<&InlineStyle> = t.iter().flat_map(|i| &i.styles).collect();
        assert!(styles_concat.contains(&&InlineStyle::Italic));
    } else {
        panic!("type de bloc inattendu");
    }
}

/// Page avec title modifiable, cover, et blocs imbriqués — scénario page Notion.
#[test]
fn test_flux_page_complete() {
    let store = store_temp();

    let doc = create_document(&store, "Brouillon").unwrap();

    // Renomme et ajoute une cover
    update_document_title(&store, doc.id, "Mon projet 2025").unwrap();
    update_document_cover(&store, doc.id, Some("🚀".to_string())).unwrap();

    // Structure : Heading → paragraphes imbriqués
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

    // Recharge et vérifie tout
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
