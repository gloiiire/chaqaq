use uuid::Uuid;
use chaqaq::application::use_cases::{
    ajouter_bloc, creer_document, modifier_bloc, obtenir_document,
    reordonner_blocs, sauvegarder_bloc_edite, supprimer_bloc,
};
use chaqaq::domain::document::{BlockContent, InlineStyle, InlineText};
use chaqaq::domain::editor::EditorState;
use chaqaq::domain::rich_text::RichText;
use chaqaq::infrastructure::json_store::JsonStore;

fn store_temp() -> JsonStore {
    let dir = std::env::temp_dir().join(format!("chaqaq_e2e_blocs_{}", Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    JsonStore::new(dir)
}

fn inlines(s: &str) -> Vec<InlineText> {
    vec![InlineText { content: s.to_string(), styles: vec![] }]
}

/// Flux complet : créer, éditer, toggle, supprimer, recharger.
#[test]
fn test_flux_edition_complete() {
    let store = store_temp();

    // Crée un document avec plusieurs types de blocs
    let doc = creer_document(&store, "Ma page").unwrap();
    let doc = ajouter_bloc(&store, doc.id,
        BlockContent::Heading { text: inlines("Introduction"), level: 1 }).unwrap();
    let doc = ajouter_bloc(&store, doc.id,
        BlockContent::Text(inlines("Premier paragraphe"))).unwrap();
    let doc = ajouter_bloc(&store, doc.id,
        BlockContent::Todo { text: inlines("Relire"), done: false }).unwrap();

    let id_heading = doc.blocks[0].id;
    let id_para    = doc.blocks[1].id;
    let id_todo    = doc.blocks[2].id;

    // Édite le heading via EditorState
    let rt = RichText::from(&inlines("Introduction révisée"));
    sauvegarder_bloc_edite(&store, doc.id, id_heading, &EditorState::nouveau(rt)).unwrap();

    // Édite le paragraphe avec un style gras
    let inlines_gras = vec![InlineText {
        content: "Texte en gras".to_string(),
        styles: vec![InlineStyle::Bold],
    }];
    let rt = RichText::from(&inlines_gras);
    sauvegarder_bloc_edite(&store, doc.id, id_para, &EditorState::nouveau(rt)).unwrap();

    // Toggle la todo
    modifier_bloc(&store, doc.id, id_todo,
        BlockContent::Todo { text: inlines("Relire"), done: true }).unwrap();

    // Recharge et vérifie tout
    let recharge = obtenir_document(&store, doc.id).unwrap();
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

    let doc = creer_document(&store, "Flux").unwrap();
    let doc = ajouter_bloc(&store, doc.id, BlockContent::Text(inlines("Alpha"))).unwrap();
    let doc = ajouter_bloc(&store, doc.id, BlockContent::Text(inlines("Beta"))).unwrap();
    let doc = ajouter_bloc(&store, doc.id, BlockContent::Text(inlines("Gamma"))).unwrap();
    let doc = ajouter_bloc(&store, doc.id, BlockContent::Divider).unwrap();

    let id_alpha = doc.blocks[0].id;
    let id_beta  = doc.blocks[1].id;
    let id_gamma = doc.blocks[2].id;
    let id_div   = doc.blocks[3].id;

    // Réordonne : Divider, Gamma, Alpha, Beta
    reordonner_blocs(&store, doc.id, vec![id_div, id_gamma, id_alpha, id_beta]).unwrap();

    let apres_reordre = obtenir_document(&store, doc.id).unwrap();
    assert_eq!(apres_reordre.blocks[0].id, id_div);
    assert_eq!(apres_reordre.blocks[1].id, id_gamma);

    // Supprime Divider
    supprimer_bloc(&store, doc.id, id_div).unwrap();

    let final_doc = obtenir_document(&store, doc.id).unwrap();
    assert_eq!(final_doc.blocks.len(), 3);
    assert_eq!(final_doc.blocks[0].id, id_gamma);
}

/// Vérifie que EditorState préserve les styles lors d'une sauvegarde.
#[test]
fn test_styles_preserves_apres_sauvegarde_bloc() {
    let store = store_temp();

    let inlines_styled = vec![
        InlineText { content: "normal ".to_string(), styles: vec![] },
        InlineText { content: "italique".to_string(), styles: vec![InlineStyle::Italic] },
    ];
    let doc = creer_document(&store, "Style").unwrap();
    let doc = ajouter_bloc(&store, doc.id, BlockContent::Text(inlines_styled.clone())).unwrap();
    let block_id = doc.blocks[0].id;

    // Sauvegarde via EditorState (round-trip RichText → Vec<InlineText>)
    let rt = RichText::from(&inlines_styled);
    sauvegarder_bloc_edite(&store, doc.id, block_id, &EditorState::nouveau(rt)).unwrap();

    let recharge = obtenir_document(&store, doc.id).unwrap();
    if let BlockContent::Text(t) = &recharge.blocks[0].content {
        let styles_concat: Vec<&InlineStyle> = t.iter().flat_map(|i| &i.styles).collect();
        assert!(styles_concat.contains(&&InlineStyle::Italic));
    } else {
        panic!("type de bloc inattendu");
    }
}
