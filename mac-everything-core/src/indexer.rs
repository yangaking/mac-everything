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
    AddDir(PathBuf),
    RemoveDir(PathBuf),
}

/// A compact, contiguous string pool to eliminate heap fragmentation and save massive memory
pub struct StringPool {
    pub buffer: Vec<u8>,
}

impl StringPool {
    pub fn new() -> Self {
        // Pre-allocate 1 byte so that offset 0 is safe for 'empty' or 'null'
        Self { buffer: vec![0] }
    }
    
    pub fn add(&mut self, s: &str) -> (u32, u16) {
        if s.is_empty() { return (0, 0); }
        let start = self.buffer.len() as u32;
        self.buffer.extend_from_slice(s.as_bytes());
        let len = s.len() as u16;
        (start, len)
    }
    
    pub fn get(&self, start: u32, len: u16) -> &str {
        if len == 0 { return ""; }
        unsafe {
            std::str::from_utf8_unchecked(&self.buffer[start as usize .. (start + len as u32) as usize])
        }
    }
}

/// Highly compact memory representation of a file (40 bytes total)
#[repr(C)]
#[derive(Clone, Copy)]
pub struct FileRecord {
    pub size: u64,
    pub modified_time: u64,
    pub name_start: u32,
    pub name_lower_start: u32,
    pub pinyin_start: u32,
    pub parent_id: u32,
    pub name_len: u16,
    pub name_lower_len: u16,
    pub pinyin_len: u16,
    pub is_dir: u8,
}

/// Shared path filter: returns true if the path should be excluded from the index.
///
/// Excludes hidden entries (at depth > 0) and non-CloudStorage `~/Library`
/// internals (caches, containers) so they stay out of both the initial scan and
/// hot updates. A scan root (depth 0) is never excluded.
fn is_excluded(path: &Path, file_name: &str, depth: usize) -> bool {
    if depth > 0 && file_name.starts_with('.') {
        return true;
    }
    let p_str = path.to_string_lossy();
    if p_str.contains("/Library/") && !p_str.contains("/Library/CloudStorage") {
        return true;
    }
    false
}

pub struct Indexer {
    pub records: RwLock<Vec<FileRecord>>,
    pub dir_paths: RwLock<Vec<String>>,
    pub dir_map: RwLock<HashMap<String, u32>>,
    pub string_pool: RwLock<StringPool>,
    pub pending_events: Mutex<Vec<HotEvent>>,
    pub roots: RwLock<Vec<String>>,
    pub wasted_bytes: Mutex<usize>,
}

impl Indexer {
    pub fn new() -> Self {
        Self {
            records: RwLock::new(Vec::new()),
            dir_paths: RwLock::new(Vec::new()),
            dir_map: RwLock::new(HashMap::new()),
            string_pool: RwLock::new(StringPool::new()),
            pending_events: Mutex::new(Vec::new()),
            roots: RwLock::new(Vec::new()),
            wasted_bytes: Mutex::new(0),
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
        let mut pool = StringPool::new();
        
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
                
                // Skip hidden files/directories and Library internals (shared filter).
                if is_excluded(path, &file_name, depth) {
                    if is_dir { it.skip_current_dir(); }
                    continue;
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

                let (name_start, name_len) = pool.add(&name_str);
                let (name_lower_start, name_lower_len) = if name_lower == name_str {
                    (name_start, name_len)
                } else {
                    pool.add(&name_lower)
                };
                let (pinyin_start, pinyin_len) = if let Some(py) = pinyin_opt {
                    pool.add(&py)
                } else {
                    (0, 0)
                };

                records.push(FileRecord {
                    size,
                    modified_time,
                    name_start,
                    name_lower_start,
                    pinyin_start,
                    parent_id,
                    name_len,
                    name_lower_len,
                    pinyin_len,
                    is_dir: is_dir as u8,
                });
            }
        }
        
        *self.records.write().unwrap() = records;
        *self.dir_paths.write().unwrap() = dir_paths;
        *self.dir_map.write().unwrap() = dir_map;
        *self.string_pool.write().unwrap() = pool;
        
        let root_strings = roots.iter().map(|p| p.as_ref().to_string_lossy().to_string()).collect();
        *self.roots.write().unwrap() = root_strings;
        *self.wasted_bytes.lock().unwrap() = 0;
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
                HotEvent::Add(p)
                | HotEvent::Remove(p)
                | HotEvent::AddDir(p)
                | HotEvent::RemoveDir(p) => {
                    latest_events.insert(p.clone(), ev);
                }
            }
        }

        let mut removes = Vec::new();
        let mut adds = Vec::new();
        let mut remove_dirs = Vec::new();
        let mut add_dirs = Vec::new();

        for (path, ev) in latest_events {
            match ev {
                HotEvent::Remove(_) => {
                    removes.push(path);
                },
                HotEvent::Add(_) => {
                    removes.push(path.clone());
                    adds.push(path);
                },
                HotEvent::RemoveDir(_) => {
                    remove_dirs.push(path);
                },
                HotEvent::AddDir(_) => {
                    add_dirs.push(path);
                },
            }
        }

        // Expand each AddDir into per-entry adds by walking the subtree (no locks held).
        for dir in add_dirs {
            let mut it = WalkDir::new(&dir).follow_links(false).into_iter();
            loop {
                let entry = match it.next() {
                    None => break,
                    Some(Err(_)) => continue,
                    Some(Ok(entry)) => entry,
                };
                let path = entry.path();
                let file_name = entry.file_name().to_string_lossy();
                let is_dir = entry.file_type().is_dir();
                if is_excluded(path, &file_name, entry.depth()) {
                    if is_dir { it.skip_current_dir(); }
                    continue;
                }
                if is_dir && file_name.ends_with(".app") {
                    it.skip_current_dir();
                    continue;
                }
                adds.push(path.to_path_buf());
            }
        }

        if removes.is_empty() && adds.is_empty() && remove_dirs.is_empty() {
            return;
        }

        // PRE-PROCESS adds without holding the lock!
        // This avoids blocking the main thread's search() when there are thousands of FSEvents (e.g. after waking from sleep).
        let mut pre_parsed_adds = Vec::new();
        for path in adds {
            let file_name = match path.file_name() {
                Some(n) => n.to_string_lossy(),
                None => continue,
            };
            if is_excluded(&path, &file_name, 1) { continue; }
            
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
                        pinyin_opt = Some(format!("{}\0{}", full_py, initial_py));
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
            let (name_lower_start, name_lower_len) = if name_lower == name_str {
                (name_start, name_len)
            } else {
                pool.add(&name_lower)
            };
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
                is_dir: is_dir as u8,
            });
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

        let mut should_rebuild = false;

        // Subtree removal: compute the set of parent ids under each removed directory,
        // plus each removed directory's own (parent_id, name) identity.
        let mut remove_subtree_ids: HashSet<u32> = HashSet::new();
        let mut remove_subtree_own: Vec<(u32, String)> = Vec::new();
        for dir in &remove_dirs {
            let d_str = dir.to_string_lossy().to_string();
            let d_prefix = format!("{}/", d_str);
            for (i, p) in dir_paths.iter().enumerate() {
                if *p == d_str || p.starts_with(&d_prefix) {
                    remove_subtree_ids.insert(i as u32);
                }
            }
            if let (Some(parent), Some(name)) = (dir.parent(), dir.file_name()) {
                let parent_str = parent.to_string_lossy().to_string();
                if let Some(&pid) = dir_map.get(&parent_str) {
                    remove_subtree_own.push((pid, name.to_string_lossy().to_string()));
                }
            }
        }

        let max_id = dir_paths.len();
        let mut has_removes = vec![false; max_id];
        for &pid in removes_map.keys() {
            if (pid as usize) < max_id {
                has_removes[pid as usize] = true;
            }
        }

        if !removes_map.is_empty() || !remove_subtree_ids.is_empty() || !remove_subtree_own.is_empty() {
            let mut local_wasted = 0;
            records.retain(|r| {
                // Single-file/dir removal by (parent_id, name).
                if (r.parent_id as usize) < max_id && has_removes[r.parent_id as usize] {
                    if let Some(names) = removes_map.get(&r.parent_id) {
                        let name = pool.get(r.name_start, r.name_len);
                        if names.contains(name) {
                            local_wasted += r.name_len as usize + r.name_lower_len as usize + r.pinyin_len as usize;
                            return false;
                        }
                    }
                }
                // Subtree removal: any record whose parent is under a removed directory.
                if remove_subtree_ids.contains(&r.parent_id) {
                    local_wasted += r.name_len as usize + r.name_lower_len as usize + r.pinyin_len as usize;
                    return false;
                }
                // The removed directory's own record.
                for (pid, name) in &remove_subtree_own {
                    if r.parent_id == *pid && pool.get(r.name_start, r.name_len) == name {
                        local_wasted += r.name_len as usize + r.name_lower_len as usize + r.pinyin_len as usize;
                        return false;
                    }
                }
                true
            });

            let mut w = self.wasted_bytes.lock().unwrap();
            *w += local_wasted;
        }

        // Check if we should rebuild (either too much wasted space or total pool size too large)
        {
            let w = self.wasted_bytes.lock().unwrap();
            // Rebuild if we have accumulated more than 50MB of dead string fragments.
            // DO NOT check absolute pool size here, because users with 1M+ files will naturally exceed 150MB,
            // which would cause an infinite rebuild loop!
            if *w > 50 * 1024 * 1024 {
                should_rebuild = true;
            }
        }

        // Append new
        records.extend(new_records);
        
        // Drop locks to avoid deadlock during rebuild
        drop(records);
        drop(dir_paths);
        drop(dir_map);
        drop(pool);
        
        if should_rebuild {
            let roots = self.roots.read().unwrap().clone();
            self.scan_directories(&roots);
        }
    }

    fn parse_single_path(path: &Path, pool: &mut StringPool, dir_paths: &mut Vec<String>, dir_map: &mut HashMap<String, u32>) -> Option<FileRecord> {
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

        let (name_start, name_len) = pool.add(&name_str);
        let (name_lower_start, name_lower_len) = if name_lower == name_str {
            (name_start, name_len)
        } else {
            pool.add(&name_lower)
        };
        let (pinyin_start, pinyin_len) = if let Some(py) = pinyin_opt {
            pool.add(&py)
        } else {
            (0, 0)
        };

        Some(FileRecord {
            size,
            modified_time,
            name_start,
            name_lower_start,
            pinyin_start,
            parent_id,
            name_len,
            name_lower_len,
            pinyin_len,
            is_dir: is_dir as u8,
        })
    }

    /// Evaluates a query node against a file record and returns a matching score
    fn evaluate_node_scored(node: &crate::query_parser::QueryNode, record: &FileRecord, pool: &StringPool, dir_paths: &[String], enable_path_search: bool, now: u64) -> Option<i32> {
        use crate::query_parser::{QueryNode, SizeOp, DateOp};
        let name_lower = pool.get(record.name_lower_start, record.name_lower_len);
        
        match node {
            QueryNode::Contains(s) => {
                let mut best_score = None;
                
                if name_lower == *s { best_score = Some(100); }
                else if record.pinyin_len > 0 {
                    let py = pool.get(record.pinyin_start, record.pinyin_len);
                    let mut split = py.split('\0');
                    if let (Some(full), Some(init)) = (split.next(), split.next()) {
                        if full == s { best_score = Some(90); }
                        else if name_lower.starts_with(s) { best_score = Some(80); }
                        else if full.starts_with(s) { best_score = Some(70); }
                        else if init == s { best_score = Some(65); }
                        else if name_lower.contains(s) { best_score = Some(50); }
                        else if full.contains(s) && s.len() > 1 { best_score = Some(40); }
                        else if init.contains(s) { best_score = Some(30); }
                    }
                } else {
                    if name_lower.starts_with(s) { best_score = Some(80); }
                    else if name_lower.contains(s) { best_score = Some(50); }
                }
                
                // Extra points for precise suffix match (e.g. searching "pdf" matching ".pdf")
                if let Some(dot_idx) = name_lower.rfind('.') {
                    if &name_lower[dot_idx + 1..] == s {
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
                if let Some(dot_idx) = name_lower.rfind('.') {
                    if &name_lower[dot_idx + 1..] == ext {
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
                let name = pool.get(record.name_start, record.name_len);
                if re.is_match(name) {
                    Some(10)
                } else {
                    None
                }
            },
            QueryNode::Size(op) => {
                match op {
                    SizeOp::Gt(val) => if record.size > *val { Some(10) } else { None },
                    SizeOp::Lt(val) => if record.size < *val { Some(10) } else { None },
                    SizeOp::Eq(val) => if record.size == *val { Some(10) } else { None },
                }
            },
            QueryNode::Date(op) => {
                let one_day = 86400;
                match op {
                    DateOp::Today => if record.modified_time + one_day > now { Some(10) } else { None },
                    DateOp::Yesterday => if record.modified_time + one_day * 2 > now && record.modified_time + one_day <= now { Some(10) } else { None },
                    DateOp::ThisWeek => if record.modified_time + one_day * 7 > now { Some(10) } else { None },
                    DateOp::ThisMonth => if record.modified_time + one_day * 30 > now { Some(10) } else { None },
                    DateOp::Gt(val) => if record.modified_time > *val { Some(10) } else { None },
                    DateOp::Lt(val) => if record.modified_time < *val { Some(10) } else { None },
                }
            },
            QueryNode::Kind(kind) => {
                if let Some(dot_idx) = name_lower.rfind('.') {
                    let ext = &name_lower[dot_idx + 1..];
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
                    if let Some(score) = Self::evaluate_node_scored(n, record, pool, dir_paths, enable_path_search, now) {
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
                    if let Some(score) = Self::evaluate_node_scored(n, record, pool, dir_paths, enable_path_search, now) {
                        match max {
                            Some(v) => if score > v { max = Some(score); },
                            None => max = Some(score),
                        }
                    }
                }
                max
            },
            QueryNode::Not(node) => {
                if Self::evaluate_node_scored(node, record, pool, dir_paths, enable_path_search, now).is_none() {
                    Some(0)
                } else {
                    None
                }
            },
            QueryNode::NoMatch => None,
        }
    }

    /// High-performance parallel search with scoring and sorting
    pub fn search(&self, query_string: &str, limit: usize, enable_path_search: bool, sort_col: u8, sort_asc: bool) -> Vec<String> {
        if limit == 0 {
            return Vec::new();
        }

        let records = self.records.read().unwrap();
        let dir_paths = self.dir_paths.read().unwrap();
        let pool = self.string_pool.read().unwrap();
        
        let query_ast = crate::query_parser::QueryParser::parse(query_string);
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs();
        
        // Multi-threaded parallel iterator via Rayon
        let mut matched_records: Vec<(i32, FileRecord, bool)> = records
            .par_iter()
            .filter_map(|&r| {
                if let Some(score) = Self::evaluate_node_scored(&query_ast, &r, &pool, &dir_paths, enable_path_search, now) {
                    let name_lower = pool.get(r.name_lower_start, r.name_lower_len);
                    let is_app = name_lower.ends_with(".app");
                    Some((score, r, is_app))
                } else {
                    None
                }
            })
            .collect();
            
        // Sort
        let cmp_fn = |a: &(i32, FileRecord, bool), b: &(i32, FileRecord, bool)| -> std::cmp::Ordering {
            let app_cmp = b.2.cmp(&a.2); // Pin apps to top
            if app_cmp != std::cmp::Ordering::Equal { return app_cmp; }
            
            let name_lower_a = pool.get(a.1.name_lower_start, a.1.name_lower_len);
            let name_lower_b = pool.get(b.1.name_lower_start, b.1.name_lower_len);

            match sort_col {
                1 => {
                    // Name
                    if sort_asc {
                        name_lower_a.cmp(name_lower_b)
                    } else {
                        name_lower_b.cmp(name_lower_a)
                    }
                },
                2 => {
                    // Size
                    let cmp = if sort_asc {
                        a.1.size.cmp(&b.1.size)
                    } else {
                        b.1.size.cmp(&a.1.size)
                    };
                    if cmp == std::cmp::Ordering::Equal {
                        name_lower_a.cmp(name_lower_b)
                    } else {
                        cmp
                    }
                },
                3 => {
                    // ModifiedTime
                    let cmp = if sort_asc {
                        a.1.modified_time.cmp(&b.1.modified_time)
                    } else {
                        b.1.modified_time.cmp(&a.1.modified_time)
                    };
                    if cmp == std::cmp::Ordering::Equal {
                        name_lower_a.cmp(name_lower_b)
                    } else {
                        cmp
                    }
                },
                4 => {
                    // Kind (Extension)
                    let ext_a = name_lower_a.split('.').last().unwrap_or("");
                    let ext_b = name_lower_b.split('.').last().unwrap_or("");
                    let cmp = if sort_asc {
                        ext_a.cmp(ext_b)
                    } else {
                        ext_b.cmp(ext_a)
                    };
                    if cmp == std::cmp::Ordering::Equal {
                        name_lower_a.cmp(name_lower_b)
                    } else {
                        cmp
                    }
                },
                _ => {
                    // Default: Score desc, then ModifiedTime desc, then Name asc
                    let cmp = b.0.cmp(&a.0);
                    if cmp == std::cmp::Ordering::Equal {
                        let t_cmp = b.1.modified_time.cmp(&a.1.modified_time);
                        if t_cmp == std::cmp::Ordering::Equal {
                            name_lower_a.cmp(name_lower_b)
                        } else {
                            t_cmp
                        }
                    } else {
                        cmp
                    }
                }
            }
        };

        if matched_records.len() > limit {
            matched_records.select_nth_unstable_by(limit - 1, cmp_fn);
            matched_records.truncate(limit);
        }
        matched_records.sort_unstable_by(cmp_fn);
            
        // Truncate to limit and construct full paths
        matched_records.into_iter()
            .take(limit)
            .map(|(_, r, _)| {
                let parent_path = &dir_paths[r.parent_id as usize];
                let name = pool.get(r.name_start, r.name_len);
                format!("{}/{}", parent_path, name)
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

        // search "weixin" should rank weixin.txt (80) > 微信_wechat.txt (70) > weixing.txt (50)
        let results = indexer.search("weixin", 10, false, 0, false);
        assert_eq!(results[0], format!("{}/weixin.txt", root.to_string_lossy()));
        
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

    #[test]
    fn test_search_limit_zero_does_not_panic() {
        let dir = tempdir().unwrap();
        let root = dir.path();
        fs::write(root.join("a.txt"), "hello").unwrap();

        let indexer = Indexer::new();
        indexer.scan_directories(&[root]);

        // limit == 0 must return an empty result set without underflowing
        let res = indexer.search("a", 0, false, 0, false);
        assert!(res.is_empty(), "limit==0 should yield no results");
    }

    #[test]
    fn test_is_excluded_filter() {
        use std::path::Path;

        // Hidden entries at depth > 0 are excluded
        assert!(is_excluded(Path::new("/Users/x/.hidden"), ".hidden", 1));
        // Library internals (non-cloud) are excluded
        assert!(is_excluded(Path::new("/Users/x/Library/Caches/foo"), "foo", 1));
        assert!(is_excluded(Path::new("/Users/x/Library/Group Containers/a"), "a", 1));
        // Cloud storage mirrors are allowed
        assert!(!is_excluded(Path::new("/Users/x/Library/CloudStorage/OneDrive/f"), "f", 1));
        // Normal files are allowed
        assert!(!is_excluded(Path::new("/Users/x/Documents/a.txt"), "a.txt", 1));
        // The scan root itself (depth 0) is never excluded, even if hidden-named
        assert!(!is_excluded(Path::new("/tmp/.tmpABC"), ".tmpABC", 0));
    }

    #[test]
    fn test_lowercase_name_dedup_reduces_pool() {
        let dir = tempdir().unwrap();
        fs::write(dir.path().join("alllowercase.txt"), "x").unwrap();

        let indexer = Indexer::new();
        indexer.scan_directories(&[dir.path()]);

        // For a fully-lowercase name, name_lower must alias name (no duplicate pool entry).
        let records = indexer.records.read().unwrap();
        let pool = indexer.string_pool.read().unwrap();
        let file_record = records
            .iter()
            .find(|r| pool.get(r.name_start, r.name_len) == "alllowercase.txt")
            .expect("file record should exist");
        assert_eq!(file_record.name_start, file_record.name_lower_start);
        assert_eq!(file_record.name_len, file_record.name_lower_len);
    }

    #[test]
    fn test_directory_move_updates_index() {
        let dir = tempdir().unwrap();
        let root = dir.path();
        fs::create_dir(root.join("old")).unwrap();
        fs::write(root.join("old").join("data.txt"), "x").unwrap();

        let indexer = Indexer::new();
        indexer.scan_directories(&[root]);

        // "data.txt" is indexed under "old".
        let before = indexer.search("data", 10, false, 0, false);
        assert_eq!(before.len(), 1);
        assert!(before[0].contains("/old/"), "unexpected path: {}", before[0]);

        // Simulate a directory move: FSEvents reports remove(old) + create(new).
        fs::rename(root.join("old"), root.join("new")).unwrap();
        indexer.enqueue_event(HotEvent::RemoveDir(root.join("old")));
        indexer.enqueue_event(HotEvent::AddDir(root.join("new")));
        indexer.apply_updates();

        // "data.txt" must now be under "new", with no stale "old" entry.
        let after = indexer.search("data", 10, false, 0, false);
        assert_eq!(after.len(), 1, "expected exactly one result, got {:?}", after);
        assert!(after[0].contains("/new/"), "unexpected path: {}", after[0]);
    }

    #[test]
    fn test_remove_dir_removes_subtree() {
        let dir = tempdir().unwrap();
        let root = dir.path();
        fs::create_dir_all(root.join("sub").join("deep")).unwrap();
        fs::write(root.join("sub").join("alpha_file.txt"), "x").unwrap();
        fs::write(root.join("sub").join("deep").join("beta_file.txt"), "x").unwrap();

        let indexer = Indexer::new();
        indexer.scan_directories(&[root]);
        assert_eq!(indexer.search("alpha_file", 10, false, 0, false).len(), 1);
        assert_eq!(indexer.search("beta_file", 10, false, 0, false).len(), 1);

        fs::remove_dir_all(root.join("sub")).unwrap();
        indexer.enqueue_event(HotEvent::RemoveDir(root.join("sub")));
        indexer.apply_updates();

        assert_eq!(indexer.search("alpha_file", 10, false, 0, false).len(), 0);
        assert_eq!(indexer.search("beta_file", 10, false, 0, false).len(), 0);
    }

    #[test]
    fn test_invalid_regex_returns_empty() {
        let dir = tempdir().unwrap();
        fs::write(dir.path().join("report.txt"), "x").unwrap();

        let indexer = Indexer::new();
        indexer.scan_directories(&[dir.path()]);

        // An invalid regex must yield no results, not match everything.
        let res = indexer.search("regex:[invalid", 100, false, 0, false);
        assert!(res.is_empty(), "invalid regex should match nothing, got {:?}", res);
    }

    #[test]
    fn test_size_exact_match() {
        let dir = tempdir().unwrap();
        fs::write(dir.path().join("ten_kb.bin"), vec![0u8; 10240]).unwrap();
        fs::write(dir.path().join("small.txt"), "x").unwrap();

        let indexer = Indexer::new();
        indexer.scan_directories(&[dir.path()]);

        let res = indexer.search("size:10kb", 100, false, 0, false);
        assert!(res.iter().any(|p| p.ends_with("ten_kb.bin")), "expected ten_kb.bin, got {:?}", res);
        assert!(!res.iter().any(|p| p.ends_with("small.txt")), "small.txt should not match size:10kb");
    }

    #[test]
    fn test_thisweek_matches_recent_file() {
        let dir = tempdir().unwrap();
        fs::write(dir.path().join("recent_file.txt"), "x").unwrap();

        let indexer = Indexer::new();
        indexer.scan_directories(&[dir.path()]);

        let res = indexer.search("date:thisweek", 100, false, 0, false);
        assert!(res.iter().any(|p| p.ends_with("recent_file.txt")), "recent file should match thisweek");
    }

    #[test]
    fn test_regex_shorthand_case_insensitive() {
        let dir = tempdir().unwrap();
        fs::write(dir.path().join("README.txt"), "x").unwrap();

        let indexer = Indexer::new();
        indexer.scan_directories(&[dir.path()]);

        // /readme/ must match README.txt case-insensitively (consistent with regex:).
        let res = indexer.search("/readme/", 100, false, 0, false);
        assert!(res.iter().any(|p| p.ends_with("README.txt")), "expected README.txt, got {:?}", res);
    }
}
