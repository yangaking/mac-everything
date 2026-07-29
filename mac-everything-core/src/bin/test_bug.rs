use mac_everything_core::indexer::*;
use std::fs;

fn main() {
    let indexer = Indexer::new();
    let root = "/tmp/test_bug";
    let _ = fs::create_dir_all(root);
    fs::write(format!("{}/2000 Core English Words 4_Word List_ENG.pdf", root), "hello").unwrap();
    indexer.scan_directory(root);
    
    let res = indexer.search("2000 pdf", 100, false, 0, false);
    println!("res: {:?}", res);

    let res2 = indexer.search("2000 ext:pdf", 100, false, 0, false);
    println!("2000 ext:pdf: {:?}", res2);
}
