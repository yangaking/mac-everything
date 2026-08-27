use walkdir::WalkDir;

fn main() {
    let home = std::env::var("HOME").unwrap();
    let mut it = WalkDir::new(&home).into_iter();
    for entry in it.filter_map(|e| e.ok()) {
        let p_str = entry.path().to_string_lossy();
        if p_str.contains("Library/Group Containers") {
            println!("Depth: {}, Path: {}", entry.depth(), p_str);
            break;
        }
    }
}
