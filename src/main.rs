#![allow(dead_code)]

pub mod application;
pub mod domain;
pub mod infrastructure;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let input = "Input : \"Bonjour [lien](url) suite\"";
    println!("{}\n", input);
    println!("Transformation appliqué :");
    let inlines = domain::parser::parse_inline(input);
    inlines.iter().for_each(|i| println!("{:#?}", i));
    Ok(())
}
