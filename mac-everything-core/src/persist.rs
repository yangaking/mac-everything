use std::collections::HashMap;
use std::fs::File;
use std::io::{self, BufReader, BufWriter, Read, Write};
use std::path::Path;

use crate::indexer::{FileRecord, Indexer, StringPool};

const MAGIC: [u8; 8] = *b"MEVTIDX1";
const VERSION: u32 = 2;
const HEADER_LEN: usize = 40; // magic(8) + version(4) + pool_len(8) + record_count(8) + dir_count(8) + reserved(4)

/// Returns the default on-disk snapshot path (inside the user's Application Support dir).
pub fn default_snapshot_path() -> Option<std::path::PathBuf> {
    let home = std::env::var("HOME").ok()?;
    let dir = std::path::PathBuf::from(home)
        .join("Library")
        .join("Application Support")
        .join("MacEverything");
    Some(dir.join("index.bin"))
}

/// Serialize the in-memory index to `path` in a compact fixed-layout binary format.
pub fn save_indexer(indexer: &Indexer, path: &Path) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let records = indexer.records.read().unwrap();
    let pool = indexer.string_pool.read().unwrap();
    let dir_paths = indexer.dir_paths.read().unwrap();

    let file = File::create(path)?;
    let mut w = BufWriter::new(file);

    // Header
    w.write_all(&MAGIC)?;
    w.write_all(&VERSION.to_le_bytes())?;
    w.write_all(&(pool.buffer.len() as u64).to_le_bytes())?;
    w.write_all(&(records.len() as u64).to_le_bytes())?;
    w.write_all(&(dir_paths.len() as u64).to_le_bytes())?;
    w.write_all(&[0u8; 4])?; // reserved

    // String pool (raw bytes)
    w.write_all(&pool.buffer)?;

    // FileRecord array (raw bytes; FileRecord is #[repr(C)] with only POD fields)
    let record_size = std::mem::size_of::<FileRecord>();
    let record_bytes =
        unsafe { std::slice::from_raw_parts(records.as_ptr() as *const u8, records.len() * record_size) };
    w.write_all(record_bytes)?;

    // Directory paths (length-prefixed UTF-8)
    for d in dir_paths.iter() {
        let b = d.as_bytes();
        w.write_all(&(b.len() as u32).to_le_bytes())?;
        w.write_all(b)?;
    }

    w.flush()
}

/// Load an index from `path`, validating magic/version/sizes/bounds.
///
/// Returns `Err` on any corruption so the caller can fall back to a fresh scan.
pub fn load_indexer(path: &Path) -> io::Result<Indexer> {
    let file = File::open(path)?;
    let file_len = file.metadata()?.len() as usize;
    let mut r = BufReader::new(file);

    let mut header = [0u8; HEADER_LEN];
    r.read_exact(&mut header)?;

    if &header[0..8] != &MAGIC {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "index: bad magic"));
    }
    let version = u32::from_le_bytes(header[8..12].try_into().unwrap());
    if version != VERSION {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "index: unsupported version"));
    }
    let pool_len = u64::from_le_bytes(header[12..20].try_into().unwrap()) as usize;
    let record_count = u64::from_le_bytes(header[20..28].try_into().unwrap()) as usize;
    let dir_count = u64::from_le_bytes(header[28..36].try_into().unwrap()) as usize;

    // Reject header sizes that cannot fit in the file (prevents over-allocation
    // on a corrupted record_count).
    let record_size = std::mem::size_of::<FileRecord>();
    let record_bytes_total = record_count
        .checked_mul(record_size)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "index: record count overflow"))?;
    let min_body = pool_len
        .checked_add(record_bytes_total)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "index: body size overflow"))?;
    if HEADER_LEN.checked_add(min_body).map_or(true, |m| m > file_len) {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "index: header sizes exceed file length"));
    }

    // String pool
    let mut buffer = vec![0u8; pool_len];
    r.read_exact(&mut buffer)?;
    let pool = StringPool { buffer };

    // FileRecord array: read directly into an aligned Vec<FileRecord> buffer.
    // FileRecord is #[repr(C)] with only POD fields (u64/u32/u16/u8), so any
    // fully-read byte pattern is a valid value.
    let mut records: Vec<FileRecord> = Vec::with_capacity(record_count);
    let record_bytes = unsafe {
        std::slice::from_raw_parts_mut(
            records.as_mut_ptr() as *mut u8,
            record_count * record_size,
        )
    };
    r.read_exact(record_bytes)?;
    unsafe {
        records.set_len(record_count);
    }

    // Directory paths
    let mut dir_paths = Vec::with_capacity(dir_count);
    for _ in 0..dir_count {
        let mut len_buf = [0u8; 4];
        r.read_exact(&mut len_buf)?;
        let len = u32::from_le_bytes(len_buf) as usize;
        let mut s = vec![0u8; len];
        r.read_exact(&mut s)?;
        dir_paths.push(
            String::from_utf8(s).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?,
        );
    }

    // Validate record bounds to prevent panics on corrupt data.
    let pool_len64 = pool.buffer.len() as u64;
    for rec in &records {
        if rec.parent_id as usize >= dir_paths.len() {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "index: parent_id out of range"));
        }
        if rec.name_start as u64 + rec.name_len as u64 > pool_len64
            || rec.name_lower_start as u64 + rec.name_lower_len as u64 > pool_len64
            || rec.pinyin_start as u64 + rec.pinyin_len as u64 > pool_len64
        {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "index: string offset out of range"));
        }
        if rec.is_dir > 1 {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "index: invalid is_dir flag"));
        }
    }

    // Rebuild dir_map
    let mut dir_map = HashMap::with_capacity(dir_paths.len());
    for (i, d) in dir_paths.iter().enumerate() {
        dir_map.insert(d.clone(), i as u32);
    }

    let indexer = Indexer::new();
    *indexer.records.write().unwrap() = records;
    *indexer.string_pool.write().unwrap() = pool;
    *indexer.dir_paths.write().unwrap() = dir_paths;
    *indexer.dir_map.write().unwrap() = dir_map;
    Ok(indexer)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::tempdir;

    fn build_test_index() -> (Indexer, tempfile::TempDir) {
        let dir = tempdir().unwrap();
        let root = dir.path();
        fs::write(root.join("weixin.txt"), "hello").unwrap();
        fs::write(root.join("微信_wechat.txt"), "hello").unwrap();
        fs::write(root.join("report.pdf"), "hello").unwrap();
        fs::create_dir(root.join("sub")).unwrap();
        fs::write(root.join("sub").join("nested.jpg"), "hello").unwrap();

        let indexer = Indexer::new();
        indexer.scan_directories(&[root]);
        (indexer, dir)
    }

    #[test]
    fn test_save_load_round_trip() {
        let (indexer, dir) = build_test_index();
        let path = dir.path().join("index.bin");

        save_indexer(&indexer, &path).unwrap();
        let loaded = load_indexer(&path).unwrap();

        // Search results must match after a round trip.
        let expected = indexer.search("weixin", 10, false, 0, false);
        let actual = loaded.search("weixin", 10, false, 0, false);
        assert_eq!(expected, actual);

        // All records must survive.
        assert_eq!(indexer.records.read().unwrap().len(), loaded.records.read().unwrap().len());
    }

    #[test]
    fn test_load_missing_file_errors() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("nope.bin");
        assert!(load_indexer(&path).is_err());
    }

    #[test]
    fn test_load_truncated_file_errors() {
        let (indexer, dir) = build_test_index();
        let path = dir.path().join("index.bin");
        save_indexer(&indexer, &path).unwrap();

        // Truncate to half the file length; load must fail (not panic).
        let full = fs::read(&path).unwrap();
        fs::write(&path, &full[..full.len() / 2]).unwrap();
        assert!(load_indexer(&path).is_err());
    }

    #[test]
    fn test_load_bad_magic_errors() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("index.bin");
        fs::write(&path, b"GARBAGE-DATA-NOT-AN-INDEX").unwrap();
        assert!(load_indexer(&path).is_err());
    }

    #[test]
    fn test_load_rejects_out_of_range_parent() {
        // Build an index with a record whose parent_id points past dir_paths.
        let mut indexer = Indexer::new();
        let mut pool = StringPool::new();
        let (ns, nl) = pool.add("a.txt");
        let (nls, nll) = pool.add("a.txt");
        let record = FileRecord {
            size: 0,
            modified_time: 0,
            name_start: ns,
            name_lower_start: nls,
            pinyin_start: 0,
            parent_id: 999, // out of range: only one dir is present
            name_len: nl,
            name_lower_len: nll,
            pinyin_len: 0,
            is_dir: 0,
        };
        *indexer.records.write().unwrap() = vec![record];
        *indexer.string_pool.write().unwrap() = pool;
        *indexer.dir_paths.write().unwrap() = vec!["/tmp".to_string()];
        *indexer.dir_map.write().unwrap() = HashMap::from([("/tmp".to_string(), 0u32)]);

        let dir = tempdir().unwrap();
        let path = dir.path().join("index.bin");
        save_indexer(&indexer, &path).unwrap();
        assert!(load_indexer(&path).is_err());
    }
}
