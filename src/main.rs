#![allow(dead_code)]

pub mod document;
pub mod parser;
pub mod storage;


fn main() -> Result<(), Box<dyn std::error::Error>> {
    // let mut doc = Document::new(vec![InlineText {
    //     content: String::from("Mon premier doc"),
    //     style: vec![],
    // }]);

    // doc.add_block(BlockContent::Heading {
    //     text: vec![InlineText {
    //         content: String::from("Introduction !"),
    //         style: vec![InlineStyle::Bold],
    //     }],
    //     level: 1,
    // });

    // doc.add_block(BlockContent::Quote {
    //     icon: Some(String::from("🙏")),
    //     text: vec![InlineText {
    //         content: String::from("Durant le culte de ce dimanche..."),
    //         style: vec![],
    //     }],
    // });

    // Sauvegarder
    // storage::save_document(&doc)?;
    // println!("Sauvegardé : {} ({}.json)", doc.id, doc.id);

    // Relire
    // let doc_relu = storage::load_document(doc.id)?;
    // println!("{:#?}", doc_relu);

    // let docs = get_documents()?;
    // println!("Mes documents :");
    // docs.iter().for_each(|doc| println!("{:#?}", doc));
    
    let input = "Bonjour [lien](url) suite";
    println!("\"{}\"",input);
    let inlines = parser::parse_inline(input);
    inlines.iter().for_each(|i| println!("{:#?}", i));
    Ok(())
}
