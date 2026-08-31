import re

with open("mac-everything-core/src/indexer.rs", "r") as f:
    content = f.read()

# Replace parse_single_path usage in apply_updates
old_apply_updates = """
        let mut new_records = Vec::new();
        
        // Acquire write lock to update
        let mut records = self.records.write().unwrap();
        let mut dir_paths = self.dir_paths.write().unwrap();
        let mut dir_map = self.dir_map.write().unwrap();
        let mut pool = self.string_pool.write().unwrap();

        // Parse new additions
        for path in adds {
            if let Some(record) = Self::parse_single_path(&path, &mut pool, &mut dir_paths, &mut dir_map) {
                new_records.push(record);
            }
        }
"""

new_apply_updates = """
        // PRE-PROCESS adds without holding the lock!
        // This avoids blocking the main thread's search() when there are thousands of FSEvents (e.g. after waking from sleep).
        let mut pre_parsed_adds = Vec::new();
        for path in adds {
            let file_name = match path.file_name() {
                Some(n) => n.to_string_lossy(),
                None => continue,
            };
            if file_name.starts_with('.') { continue; }
            
            if let Ok(metadata) = std::fs::symlink_metadata(&path) {
                let size = metadata.len();
                let mut modified_time = 0;
                if let Ok(sys_time) = metadata.modified() {
                    if let Ok(duration) = sys_time.duration_since(std::time::UNIX_EPOCH) {
                        modified_time = duration.as_secs();
                    }
                }
                
                let name_str = file_name.into_owned();
                let name_lower = name_str.to_lowercase();
                
                let mut pinyin_opt = None;
                if name_str.chars().any(|c| !c.is_ascii()) {
                    let mut full_py = String::new();
                    let mut initial_py = String::new();
                    for c in name_str.chars() {
                        if let Some(py) = pinyin::ToPinyin::to_pinyin(&c) {
                            let py_str = py.plain();
                            full_py.push_str(py_str);
                            if let Some(ch) = py_str.chars().next() {
                                initial_py.push(ch);
                            }
                        } else {
                            full_py.push(c.to_ascii_lowercase());
                            initial_py.push(c.to_ascii_lowercase());
                        }
                    }
                    if !full_py.is_empty() {
                        pinyin_opt = Some(format!("{}\\0{}", full_py, initial_py));
                    }
                }
                
                pre_parsed_adds.push((path.clone(), name_str, name_lower, pinyin_opt, metadata.is_dir(), size, modified_time));
            }
        }

        let mut new_records = Vec::new();
        
        // NOW Acquire write lock to update (should be extremely fast, no I/O)
        let mut records = self.records.write().unwrap();
        let mut dir_paths = self.dir_paths.write().unwrap();
        let mut dir_map = self.dir_map.write().unwrap();
        let mut pool = self.string_pool.write().unwrap();

        // Process additions into StringPool and FileRecord
        for (path, name_str, name_lower, pinyin_opt, is_dir, size, modified_time) in pre_parsed_adds {
            let parent = path.parent().unwrap_or(std::path::Path::new(""));
            let parent_str = parent.to_string_lossy().to_string();
            
            let parent_id = *dir_map.entry(parent_str.clone()).or_insert_with(|| {
                let id = dir_paths.len() as u32;
                dir_paths.push(parent_str);
                id
            });

            let (name_start, name_len) = pool.add(&name_str);
            let (name_lower_start, name_lower_len) = pool.add(&name_lower);
            let (pinyin_start, pinyin_len) = if let Some(py) = pinyin_opt {
                pool.add(&py)
            } else {
                (0, 0)
            };

            new_records.push(crate::indexer::FileRecord {
                size,
                modified_time,
                name_start,
                name_lower_start,
                pinyin_start,
                parent_id,
                name_len,
                name_lower_len,
                pinyin_len,
                is_dir,
            });
        }
"""

content = content.replace(old_apply_updates, new_apply_updates)

with open("mac-everything-core/src/indexer.rs", "w") as f:
    f.write(content)

print("Patched apply_updates!")
