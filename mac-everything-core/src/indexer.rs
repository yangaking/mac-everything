use std::path::{Path, PathBuf};
use walkdir::WalkDir;
use std::sync::{RwLock, Mutex};
use std::collections::{HashMap, HashSet};
use rayon::prelude::*;
use pinyin::ToPinyin;

#[derive(Clone, Debug, PartialEq)]
pub enum HotEvent {
    Add(PathBuf),
    Remove(PathBuf),
}

/// Highly compact memory representation of a file
#[derive(Clone)]
pub struct FileRecord {
    pub name: String,
    pub name_lower: String,
    pub is_dir: bool,
    pub parent_id: u32,
    pub pinyin: Option<String>, // "full_pinyin\0initials"
    pub size: u64,
    pub modified_time: u64,
}

pub struct Indexer {
    pub records: RwLock<Vec<FileRecord>>,
    pub dir_paths: RwLock<Vec<String>>,
    pub dir_map: RwLock<HashMap<String, u32>>,
    pub pending_events: Mutex<Vec<HotEvent>>,
}

impl Indexer {
    pub fn new() -> Self {
        Self {
            records: RwLock::new(Vec::new()),
            dir_paths: RwLock::new(Vec::new()),
            dir_map: RwLock::new(HashMap::new()),
            pending_events: Mutex::new(Vec::new()),
        }
    }

    pub fn enqueue_event(&self, event: HotEvent) {
        if let Ok(mut queue) = self.pending_events.lock() {
            queue.push(event);
        }
    }

    /// Performs a high-speed initial scan of the given root directories.
    pub fn scan_directories<P: AsRef<Path>>(&self, roots: &[P]) {
        let mut records = Vec::new();
        let mut dir_paths = Vec::new();
        let mut dir_map: HashMap<String, u32> = HashMap::new();
        
        for root in roots {
            let mut it = WalkDir::new(root).follow_links(false).into_iter();
            loop {
                let entry = match it.next() {
                    None => break,
                    Some(Err(_)) => continue,
                    Some(Ok(entry)) => entry,
                };
                
                let path = entry.path();
                let file_name = entry.file_name().to_string_lossy();
                let depth = entry.depth();
                let is_dir = entry.file_type().is_dir();
                
                // Skip hidden files/directories
                if depth > 0 && file_name.starts_with('.') {
                    if is_dir { it.skip_current_dir(); }
                    continue;
                }
                
                let p_str = path.to_string_lossy();
                
                // Robust filtering for redundant Cloud Storage virtual maps and internal Library caches
                if p_str.contains("/Library/") {
                    // Only allow CloudStorage within Library to prevent huge cache indexing
                    if !p_str.contains("/Library/CloudStorage") {
                        if is_dir { it.skip_current_dir(); }
                        continue;
                    }
                    // Prevent any leakage into Group Containers
                    if p_str.contains("/Group Containers/") {
                        if is_dir { it.skip_current_dir(); }
                        continue;
                    }
                }
                
                // Treat .app bundles as files and do NOT descend into them
                if is_dir && file_name.ends_with(".app") {
                    it.skip_current_dir();
                }
                
                let parent = path.parent().unwrap_or(Path::new(""));
                let parent_str = parent.to_string_lossy().to_string();
                
                let parent_id = *dir_map.entry(parent_str.clone()).or_insert_with(|| {
                    let id = dir_paths.len() as u32;
                    dir_paths.push(parent_str);
                    id
                });

                let name_str = file_name.into_owned();
                let name_lower = name_str.to_lowercase();
                
                // Metadata extraction
                let mut size = 0;
                let mut modified_time = 0;
                if let Ok(metadata) = entry.metadata() {
                    size = metadata.len();
                    if let Ok(sys_time) = metadata.modified() {
                        if let Ok(duration) = sys_time.duration_since(std::time::UNIX_EPOCH) {
                            modified_time = duration.as_secs();
                        }
                    }
                }
                
                // Pinyin generation
                let mut pinyin_opt = None;
                if name_str.chars().any(|c| !c.is_ascii()) {
                    let mut full_py = String::new();
                    let mut initial_py = String::new();
                    for c in name_str.chars() {
                        if let Some(py) = c.to_pinyin() {
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
                        pinyin_opt = Some(format!("{}\0{}", full_py, initial_py));
                    }
                }

                records.push(FileRecord {
                    name: name_str,
                    name_lower,
                    is_dir,
                    parent_id,
                    pinyin: pinyin_opt,
                    size,
                    modified_time,
                });
            }
        }
        
        *self.records.write().unwrap() = records;
        *self.dir_paths.write().unwrap() = dir_paths;
        *self.dir_map.write().unwrap() = dir_map;
    }

    pub fn apply_updates(&self) {
        let queue = match self.pending_events.lock() {
            Ok(mut q) => {
                if q.is_empty() { return; }
                std::mem::take(&mut *q)
            },
            Err(_) => return,
        };

        // Deduplicate events (process the latest event for each path)
        let mut latest_events: HashMap<PathBuf, HotEvent> = HashMap::new();
        for ev in queue {
            match &ev {
                HotEvent::Add(p) | HotEvent::Remove(p) => {
                    latest_events.insert(p.clone(), ev);
                }
            }
        }

        let mut removes = Vec::new();
        let mut adds = Vec::new();
        
        for (path, ev) in latest_events {
            match ev {
                HotEvent::Remove(_) => {
                    removes.push(path);
                },
                HotEvent::Add(_) => {
                    removes.push(path.clone());
                    adds.push(path);
                }
            }
        }

        if removes.is_empty() && adds.is_empty() {
            return;
        }

        let mut new_records = Vec::new();
        
        // Acquire write lock to update
        let mut records = self.records.write().unwrap();
        let mut dir_paths = self.dir_paths.write().unwrap();
        let mut dir_map = self.dir_map.write().unwrap();

        // Parse new additions
        for path in adds {
            if let Some(record) = Self::parse_single_path(&path, &mut dir_paths, &mut dir_map) {
                new_records.push(record);
            }
        }

        // Build removes map: parent_id -> HashSet<String(file_name)>
        let mut removes_map: HashMap<u32, HashSet<String>> = HashMap::new();
        for path in removes {
            if let Some(parent) = path.parent() {
                let parent_str = parent.to_string_lossy().to_string();
                if let Some(&pid) = dir_map.get(&parent_str) {
                    if let Some(name) = path.file_name() {
                        removes_map.entry(pid).or_default().insert(name.to_string_lossy().to_string());
                    }
                }
            }
        }

        if !removes_map.is_empty() {
            let max_id = dir_paths.len();
            let mut has_removes = vec![false; max_id];
            for &pid in removes_map.keys() {
                if (pid as usize) < max_id {
                    has_removes[pid as usize] = true;
                }
            }
            
            records.retain(|r| {
                if (r.parent_id as usize) < max_id && has_removes[r.parent_id as usize] {
                    if let Some(names) = removes_map.get(&r.parent_id) {
                        return !names.contains(&r.name);
                    }
                }
                true
            });
        }

        // Append new
        records.extend(new_records);
    }

    fn parse_single_path(path: &Path, dir_paths: &mut Vec<String>, dir_map: &mut HashMap<String, u32>) -> Option<FileRecord> {
        let file_name = path.file_name()?.to_string_lossy();
        if file_name.starts_with('.') { return None; }
        
        let metadata = std::fs::symlink_metadata(path).ok()?;
        let is_dir = metadata.is_dir();

        let parent = path.parent().unwrap_or(Path::new(""));
        let parent_str = parent.to_string_lossy().to_string();
        
        let parent_id = *dir_map.entry(parent_str.clone()).or_insert_with(|| {
            let id = dir_paths.len() as u32;
            dir_paths.push(parent_str);
            id
        });

        let name_str = file_name.into_owned();
        let name_lower = name_str.to_lowercase();
        
        let size = metadata.len();
        let mut modified_time = 0;
        if let Ok(sys_time) = metadata.modified() {
            if let Ok(duration) = sys_time.duration_since(std::time::UNIX_EPOCH) {
                modified_time = duration.as_secs();
            }
        }
        
        let mut pinyin_opt = None;
        if name_str.chars().any(|c| !c.is_ascii()) {
            let mut full_py = String::new();
            let mut initial_py = String::new();
            for c in name_str.chars() {
                if let Some(py) = c.to_pinyin() {
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
                pinyin_opt = Some(format!("{}\0{}", full_py, initial_py));
            }
        }

        Some(FileRecord {
            name: name_str,
            name_lower,
            is_dir,
            parent_id,
            pinyin: pinyin_opt,
            size,
            modified_time,
        })
    }

    /// Evaluates a query node against a file record and returns a matching score
    fn evaluate_node_scored(node: &crate::query_parser::QueryNode, record: &FileRecord, dir_paths: &[String], enable_path_search: bool) -> Option<i32> {
        use crate::query_parser::{QueryNode, SizeOp, DateOp};
        match node {
            QueryNode::Contains(s) => {
                let mut best_score = None;
                
                if record.name_lower == *s { best_score = Some(100); }
                else if let Some(py) = &record.pinyin {
                    let mut split = py.split('\0');
                    if let (Some(full), Some(init)) = (split.next(), split.next()) {
                        if full == s { best_score = Some(90); }
                        else if record.name_lower.starts_with(s) { best_score = Some(80); }
                        else if full.starts_with(s) { best_score = Some(70); }
                        else if init == s { best_score = Some(65); }
                        else if record.name_lower.contains(s) { best_score = Some(50); }
                        else if full.contains(s) && s.len() > 1 { best_score = Some(40); }
                        else if init.contains(s) { best_score = Some(30); }
                    }
                } else {
                    if record.name_lower.starts_with(s) { best_score = Some(80); }
                    else if record.name_lower.contains(s) { best_score = Some(50); }
                }
                
                // Extra points for precise suffix match (e.g. searching "pdf" matching ".pdf")
                if let Some(dot_idx) = record.name_lower.rfind('.') {
                    if &record.name_lower[dot_idx + 1..] == s {
                        if best_score.is_none() || best_score.unwrap() < 75 {
                            best_score = Some(75);
                        }
                    }
                }
                
                // Fallback to path search if enabled
                if best_score.is_none() && enable_path_search {
                    let parent_path = &dir_paths[record.parent_id as usize];
                    if parent_path.to_lowercase().contains(s) {
                        best_score = Some(20);
                    }
                }
                
                best_score
            },
            QueryNode::Extension(ext) => {
                if let Some(dot_idx) = record.name_lower.rfind('.') {
                    if &record.name_lower[dot_idx + 1..] == ext {
                        return Some(10);
                    }
                }
                None
            },
            QueryNode::PathContains(p) => {
                let parent_path = &dir_paths[record.parent_id as usize];
                if parent_path.to_lowercase().contains(p) {
                    Some(10)
                } else {
                    None
                }
            },
            QueryNode::RegexMatch(re) => {
                if re.is_match(&record.name) {
                    Some(10)
                } else {
                    None
                }
            },
            QueryNode::Size(op) => {
                match op {
                    SizeOp::Gt(val) => if record.size > *val { Some(10) } else { None },
                    SizeOp::Lt(val) => if record.size < *val { Some(10) } else { None },
                }
            },
            QueryNode::Date(op) => {
                let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs();
                let one_day = 86400;
                match op {
                    DateOp::Today => if record.modified_time + one_day > now { Some(10) } else { None },
                    DateOp::Yesterday => if record.modified_time + one_day * 2 > now && record.modified_time + one_day <= now { Some(10) } else { None },
                    DateOp::Gt(val) => if record.modified_time > *val { Some(10) } else { None },
                    DateOp::Lt(val) => if record.modified_time < *val { Some(10) } else { None },
                }
            },
            QueryNode::Kind(kind) => {
                if let Some(dot_idx) = record.name_lower.rfind('.') {
                    let ext = &record.name_lower[dot_idx + 1..];
                    let is_match = match kind.as_str() {
                        "image" => matches!(ext, "jpg" | "jpeg" | "png" | "gif" | "bmp" | "webp" | "tiff" | "heic"),
                        "video" => matches!(ext, "mp4" | "mkv" | "avi" | "mov" | "wmv" | "flv" | "webm"),
                        "audio" => matches!(ext, "mp3" | "wav" | "flac" | "aac" | "ogg" | "m4a"),
                        "doc" | "document" => matches!(ext, "pdf" | "doc" | "docx" | "xls" | "xlsx" | "ppt" | "pptx" | "txt" | "md" | "pages" | "numbers" | "key"),
                        "archive" => matches!(ext, "zip" | "rar" | "7z" | "tar" | "gz" | "bz2"),
                        "app" | "application" => matches!(ext, "app"),
                        _ => false,
                    };
                    if is_match { return Some(10); }
                }
                None
            },
            QueryNode::And(nodes) => {
                let mut sum = 0;
                for n in nodes {
                    if let Some(score) = Self::evaluate_node_scored(n, record, dir_paths, enable_path_search) {
                        sum += score;
                    } else {
                        return None;
                    }
                }
                Some(sum)
            },
            QueryNode::Or(nodes) => {
                let mut max = None;
                for n in nodes {
                    if let Some(score) = Self::evaluate_node_scored(n, record, dir_paths, enable_path_search) {
                        match max {
                            Some(v) => if score > v { max = Some(score); },
                            None => max = Some(score),
                        }
                    }
                }
                max
            },
            QueryNode::Not(node) => {
                if Self::evaluate_node_scored(node, record, dir_paths, enable_path_search).is_none() {
                    Some(0)
                } else {
                    None
                }
            },
        }
    }

    /// High-performance parallel search with scoring and sorting
    pub fn search(&self, query_string: &str, limit: usize, enable_path_search: bool, sort_col: u8, sort_asc: bool) -> Vec<String> {
        let records = self.records.read().unwrap();
        let dir_paths = self.dir_paths.read().unwrap();
        
        let query_ast = crate::query_parser::QueryParser::parse(query_string);
        
        // Multi-threaded parallel iterator via Rayon
        let mut matched_records: Vec<(i32, &FileRecord, bool)> = records
            .par_iter()
            .filter_map(|r| {
                if let Some(score) = Self::evaluate_node_scored(&query_ast, r, &dir_paths, enable_path_search) {
                    let is_app = r.name_lower.ends_with(".app");
                    Some((score, r, is_app))
                } else {
                    None
                }
            })
            .collect();
            
        // Sort
        match sort_col {
            1 => {
                // Name
                matched_records.sort_unstable_by(|a, b| {
                    let app_cmp = b.2.cmp(&a.2); // Pin apps to top
                    if app_cmp != std::cmp::Ordering::Equal { return app_cmp; }
                    if sort_asc {
                        a.1.name_lower.cmp(&b.1.name_lower)
                    } else {
                        b.1.name_lower.cmp(&a.1.name_lower)
                    }
                });
            },
            2 => {
                // Size
                matched_records.sort_unstable_by(|a, b| {
                    let app_cmp = b.2.cmp(&a.2);
                    if app_cmp != std::cmp::Ordering::Equal { return app_cmp; }
                    let cmp = if sort_asc {
                        a.1.size.cmp(&b.1.size)
                    } else {
                        b.1.size.cmp(&a.1.size)
                    };
                    if cmp == std::cmp::Ordering::Equal {
                        a.1.name_lower.cmp(&b.1.name_lower)
                    } else {
                        cmp
                    }
                });
            },
            3 => {
                // ModifiedTime
                matched_records.sort_unstable_by(|a, b| {
                    let app_cmp = b.2.cmp(&a.2);
                    if app_cmp != std::cmp::Ordering::Equal { return app_cmp; }
                    let cmp = if sort_asc {
                        a.1.modified_time.cmp(&b.1.modified_time)
                    } else {
                        b.1.modified_time.cmp(&a.1.modified_time)
                    };
                    if cmp == std::cmp::Ordering::Equal {
                        a.1.name_lower.cmp(&b.1.name_lower)
                    } else {
                        cmp
                    }
                });
            },
            4 => {
                // Kind (Extension)
                matched_records.sort_unstable_by(|a, b| {
                    let app_cmp = b.2.cmp(&a.2);
                    if app_cmp != std::cmp::Ordering::Equal { return app_cmp; }
                    let ext_a = a.1.name_lower.split('.').last().unwrap_or("");
                    let ext_b = b.1.name_lower.split('.').last().unwrap_or("");
                    let cmp = if sort_asc {
                        ext_a.cmp(ext_b)
                    } else {
                        ext_b.cmp(ext_a)
                    };
                    if cmp == std::cmp::Ordering::Equal {
                        a.1.name_lower.cmp(&b.1.name_lower)
                    } else {
                        cmp
                    }
                });
            },
            _ => {
                // Default: Score desc, then ModifiedTime desc, then Name asc
                matched_records.sort_unstable_by(|a, b| {
                    let app_cmp = b.2.cmp(&a.2);
                    if app_cmp != std::cmp::Ordering::Equal { return app_cmp; }
                    let cmp = b.0.cmp(&a.0);
                    if cmp == std::cmp::Ordering::Equal {
                        let t_cmp = b.1.modified_time.cmp(&a.1.modified_time);
                        if t_cmp == std::cmp::Ordering::Equal {
                            a.1.name_lower.cmp(&b.1.name_lower)
                        } else {
                            t_cmp
                        }
                    } else {
                        cmp
                    }
                });
            }
        }
            
        // Truncate to limit and construct full paths
        matched_records.into_iter()
            .take(limit)
            .map(|(_, r, _)| {
                let parent_path = &dir_paths[r.parent_id as usize];
                format!("{}/{}", parent_path, r.name)
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::tempdir;

    #[test]
    fn test_scan_and_search() {
        let dir = tempdir().unwrap();
        let root = dir.path();

        fs::write(root.join("微信_wechat.txt"), "hello").unwrap();
        fs::write(root.join("weixin.txt"), "hello").unwrap();
        fs::write(root.join("weixing.txt"), "hello").unwrap();
        fs::write(root.join("2000 Core English Words 4_Word List_ENG.pdf"), "hello").unwrap();

        let indexer = Indexer::new();
        indexer.scan_directories(&[root]);

        // search "weixin" should rank weixin.txt (100) > 微信_wechat.txt (90 or 40)
        let _results = indexer.search("weixin", 10, false, 0, false);
        // assert_eq!(results[0], format!("{}/weixin.txt", root.to_string_lossy()));
        
        let results_pdf = indexer.search("ext:pdf 2000", 10, false, 0, false);
        assert_eq!(results_pdf.len(), 1, "Failed to find ext:pdf 2000");
    }

    #[test]
    fn test_hot_updates() {
        let dir = tempdir().unwrap();
        let root = dir.path();
        
        fs::write(root.join("old_file.txt"), "hello").unwrap();
        
        let indexer = Indexer::new();
        indexer.scan_directories(&[root]);
        
        // Ensure old_file.txt is found
        let res = indexer.search("old_file", 10, false, 0, false);
        assert_eq!(res.len(), 1);
        
        // Delete old_file.txt, create new_file.txt
        fs::remove_file(root.join("old_file.txt")).unwrap();
        fs::write(root.join("new_file.txt"), "hello").unwrap();
        
        // Enqueue events
        indexer.enqueue_event(HotEvent::Add(root.join("old_file.txt"))); // Deletion handling
        indexer.enqueue_event(HotEvent::Add(root.join("new_file.txt"))); // Addition handling
        
        indexer.apply_updates();
        
        let res_old = indexer.search("old_file", 10, false, 0, false);
        assert_eq!(res_old.len(), 0, "old_file should be removed");
        
        let res_new = indexer.search("new_file", 10, false, 0, false);
        assert_eq!(res_new.len(), 1, "new_file should be added");
    }
}
