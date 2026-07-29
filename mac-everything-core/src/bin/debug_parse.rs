use mac_everything_core::query_parser::*;

fn main() {
    let q = "ext:pdf 2000";
    let node = QueryParser::parse(q);
    println!("{:?}", node);
}
