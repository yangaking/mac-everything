use walkdir::WalkDir;
use std::path::Path;

fn main() {
    let root = "/Users/aking";
    let walker = WalkDir::new(root).into_iter().filter_entry(|e| {
        let file_name = e.file_name().to_string_lossy();
        if e.depth() > 0 && file_name.starts_with('.') {
            return false;
        }
        
        if e.depth() == 1 && file_name == "Library" {
            return true;
        }
        if e.depth() == 2 {
            if let Some(parent) = e.path().parent() {
                if let Some(parent_name) = parent.file_name() {
                    if parent_name.to_string_lossy() == "Library" && file_name != "CloudStorage" {
                        return false;
                    }
                }
            }
        }
        true
    });

    let mut cloud_files = 0;
    for entry in walker.filter_map(|e| e.ok()) {
        if entry.path().to_string_lossy().contains("CloudStorage") {
            cloud_files += 1;
        }
    }
    println!("CloudStorage files found: {}", cloud_files);
}
