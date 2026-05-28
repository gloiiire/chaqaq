use uuid::Uuid;
use chaqaq::application::error::ChaqaqError;
use chaqaq::application::use_cases::{
    ajouter_bloc, creer_document, modifier_bloc, obtenir_document,
    reordonner_blocs, sauvegarder_bloc_edite, supprimer_bloc,
};
use chaqaq::domain::document::{BlockContent, InlineText};
use chaqaq::domain::editor::EditorState;
use chaqaq::domain::rich_text::RichText;
use chaqaq::infrastructure::json_store::JsonStore;

fn store_temp() -> JsonStore {
    let dir = std::env::temp_dir().join(format!("chaqaq_blocs_{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    JsonStore::new(dir)
}

fn inlines(s: &str) -> Vec<InlineText> {
    vec![InlineText { content: s.to_string(), styles: vec![] }]
}

fn etat_depuis(s: &str) -> EditorState {
    let il = inlines(s);
    EditorState::nouveau(RichText::from(&il))
}

// ── Bridge EditorState → Block ────────────────────────────────────────────────

#[test]
fn test_sauvegarder_bloc_edite_text() {
    let store = store_temp();
    let doc = creer_document(&store, "Doc").unwrap();
    let doc = ajouter_bloc(&store, doc.id, BlockContent::Text(inlines("initial"))).unwrap();
    let block_id = doc.blocks[0].id;

    sauvegarder_bloc_edite(&store, doc.id, block_id, &etat_depuis("modifié")).unwrap();

    let recharge = obtenir_document(&store, doc.id).unwrap();
    assert!(matches!(&recharge.blocks[0].content, BlockContent::Text(t) if t[0].content == "modifié"));
}

#[test]
fn test_sauvegarder_bloc_edite_heading() {
    let store = store_temp();
    let doc = creer_document(&store, "Doc").unwrap();
    let doc = ajouter_bloc(&store, doc.id,
        BlockContent::Heading { text: inlines("titre initial"), level: 1 }).unwrap();
    let block_id = doc.blocks[0].id;

    sauvegarder_bloc_edite(&store, doc.id, block_id, &etat_depuis("titre modifié")).unwrap();

    let recharge = obtenir_document(&store, doc.id).unwrap();
    assert!(matches!(
        &recharge.blocks[0].content,
        BlockContent::Heading { text: t, level: 1 } if t[0].content == "titre modifié"
    ));
}

#[test]
fn test_sauvegarder_bloc_non_textuel_retourne_erreur() {
    let store = store_temp();
    let doc = creer_document(&store, "Doc").unwrap();
    let doc = ajouter_bloc(&store, doc.id, BlockContent::Divider).unwrap();
    let block_id = doc.blocks[0].id;

    let result = sauvegarder_bloc_edite(&store, doc.id, block_id, &etat_depuis("x"));
    assert!(matches!(result, Err(ChaqaqError::OperationInvalide(_))));
}

// ── Gestion des blocs ─────────────────────────────────────────────────────────

#[test]
fn test_modifier_bloc_toggle_todo() {
    let store = store_temp();
    let doc = creer_document(&store, "Tâches").unwrap();
    let doc = ajouter_bloc(&store, doc.id,
        BlockContent::Todo { text: inlines("faire la vaisselle"), done: false }).unwrap();
    let block_id = doc.blocks[0].id;

    modifier_bloc(&store, doc.id, block_id,
        BlockContent::Todo { text: inlines("faire la vaisselle"), done: true }).unwrap();

    let recharge = obtenir_document(&store, doc.id).unwrap();
    assert!(matches!(&recharge.blocks[0].content, BlockContent::Todo { done: true, .. }));
}

#[test]
fn test_modifier_bloc_inexistant_retourne_non_trouve() {
    let store = store_temp();
    let doc = creer_document(&store, "Doc").unwrap();
    let faux_id = Uuid::new_v4();

    let result = modifier_bloc(&store, doc.id, faux_id, BlockContent::Divider);
    assert!(matches!(result, Err(ChaqaqError::NonTrouve(_))));
}

#[test]
fn test_supprimer_bloc() {
    let store = store_temp();
    let doc = creer_document(&store, "Doc").unwrap();
    let doc = ajouter_bloc(&store, doc.id, BlockContent::Text(inlines("A"))).unwrap();
    let doc = ajouter_bloc(&store, doc.id, BlockContent::Text(inlines("B"))).unwrap();
    let id_a = doc.blocks[0].id;

    supprimer_bloc(&store, doc.id, id_a).unwrap();

    let recharge = obtenir_document(&store, doc.id).unwrap();
    assert_eq!(recharge.blocks.len(), 1);
    assert!(matches!(&recharge.blocks[0].content, BlockContent::Text(t) if t[0].content == "B"));
}

#[test]
fn test_supprimer_bloc_inexistant_retourne_non_trouve() {
    let store = store_temp();
    let doc = creer_document(&store, "Doc").unwrap();
    let result = supprimer_bloc(&store, doc.id, Uuid::new_v4());
    assert!(matches!(result, Err(ChaqaqError::NonTrouve(_))));
}

#[test]
fn test_reordonner_blocs() {
    let store = store_temp();
    let doc = creer_document(&store, "Doc").unwrap();
    let doc = ajouter_bloc(&store, doc.id, BlockContent::Text(inlines("A"))).unwrap();
    let doc = ajouter_bloc(&store, doc.id, BlockContent::Text(inlines("B"))).unwrap();
    let doc = ajouter_bloc(&store, doc.id, BlockContent::Text(inlines("C"))).unwrap();
    let id_a = doc.blocks[0].id;
    let id_b = doc.blocks[1].id;
    let id_c = doc.blocks[2].id;

    reordonner_blocs(&store, doc.id, vec![id_c, id_a, id_b]).unwrap();

    let recharge = obtenir_document(&store, doc.id).unwrap();
    assert_eq!(recharge.blocks[0].id, id_c);
    assert_eq!(recharge.blocks[1].id, id_a);
    assert_eq!(recharge.blocks[2].id, id_b);
}

#[test]
fn test_reordonner_blocs_partiels_conserve_le_reste() {
    let store = store_temp();
    let doc = creer_document(&store, "Doc").unwrap();
    let doc = ajouter_bloc(&store, doc.id, BlockContent::Text(inlines("A"))).unwrap();
    let doc = ajouter_bloc(&store, doc.id, BlockContent::Text(inlines("B"))).unwrap();
    let doc = ajouter_bloc(&store, doc.id, BlockContent::Text(inlines("C"))).unwrap();
    let id_a = doc.blocks[0].id;
    let id_c = doc.blocks[2].id;

    // Réordonne seulement A et C ; B est non mentionné → va en fin
    reordonner_blocs(&store, doc.id, vec![id_c, id_a]).unwrap();

    let recharge = obtenir_document(&store, doc.id).unwrap();
    assert_eq!(recharge.blocks.len(), 3);
    assert_eq!(recharge.blocks[0].id, id_c);
    assert_eq!(recharge.blocks[1].id, id_a);
}
