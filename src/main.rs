use chaqaq::domain::parser::parse_inline;

fn main() {
    let input = "Input : \"Bonjour [lien](url) suite\"";
    println!("{}\n", input);
    println!("Transformation appliqué :");
    let inlines = parse_inline(input);
    inlines.iter().for_each(|i| println!("{:#?}", i));
}
