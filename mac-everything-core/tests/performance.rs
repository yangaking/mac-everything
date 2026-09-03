//! Performance baseline harness.
//!
//! Run with (release build is required for meaningful numbers):
//!   cargo test --release -- --ignored --nocapture
//!
//! Hard targets (from AGENTS.md / plan):
//!   - 1M paths, plain keyword search  < 10ms
//!   - 1M paths, regex search          < 30ms
//!   - index file                       < 50MB   (asserted after persistence lands)
//!   - cold start                       < 500ms  (asserted after persistence lands)

use mac_everything_core::indexer::{FileRecord, Indexer, StringPool};
use std::collections::HashMap;
use std::time::Instant;

const N: usize = 1_000_000;
const LIMIT: usize = 100;

/// Builds an in-memory index of `n` synthetic file paths without touching disk.
/// 1 in 5 files has a `.pdf` extension; all names contain the literal "report".
fn build_synthetic_index(n: usize) -> Indexer {
    let mut pool = StringPool::new();
    let mut dir_paths = Vec::new();
    let mut dir_map: HashMap<String, u32> = HashMap::new();

    let dirs = [
        "/Users/demo/Documents",
        "/Users/demo/Downloads",
        "/Users/demo/Music",
        "/Users/demo/Pictures",
        "/Users/demo/Movies",
    ];
    for d in dirs.iter() {
        dir_map.insert((*d).to_string(), dir_paths.len() as u32);
        dir_paths.push((*d).to_string());
    }

    let exts = ["pdf", "jpg", "mp3", "txt", "mp4"];
    let mut records = Vec::with_capacity(n);
    for i in 0..n {
        let dir_id = (i % dirs.len()) as u32;
        let ext = exts[i % exts.len()];
        let name = format!("report_{:07}.{}", i, ext);
        let name_lower = name.to_lowercase();
        let (ns, nl) = pool.add(&name);
        let (nls, nll) = pool.add(&name_lower);
        records.push(FileRecord {
            size: (i as u64 + 1) * 1024,
            modified_time: 1_700_000_000 + i as u64,
            name_start: ns,
            name_lower_start: nls,
            pinyin_start: 0,
            parent_id: dir_id,
            name_len: nl,
            name_lower_len: nll,
            pinyin_len: 0,
            is_dir: 0,
        });
    }

    let indexer = Indexer::new();
    *indexer.records.write().unwrap() = records;
    *indexer.dir_paths.write().unwrap() = dir_paths;
    *indexer.dir_map.write().unwrap() = dir_map;
    *indexer.string_pool.write().unwrap() = pool;
    indexer
}

fn median_ms(timings: &mut [u128]) -> u128 {
    timings.sort_unstable();
    timings[timings.len() / 2]
}

/// Worst-case full-scan benchmark: "report" matches every one of the 1M records,
/// exercising the collect-all + sort + truncate path end to end.
#[test]
#[ignore = "performance benchmark: run with `cargo test --release -- --ignored --nocapture`"]
fn benchmark_search_1m() {
    let indexer = build_synthetic_index(N);

    // Warm-up (also forces lazy rayon thread-pool init)
    for _ in 0..5 {
        let _ = indexer.search("report", LIMIT, false, 0, false);
        let _ = indexer.search("regex:\\.pdf$", LIMIT, false, 0, false);
    }

    // Plain keyword: matches all 1M records (worst case).
    let mut plain = Vec::with_capacity(7);
    for _ in 0..7 {
        let t = Instant::now();
        let r = indexer.search("report", LIMIT, false, 0, false);
        plain.push(t.elapsed().as_millis());
        assert_eq!(r.len(), LIMIT);
    }
    let plain_median = median_ms(&mut plain);

    // Regex: only ~200k of 1M records match.
    let mut re = Vec::with_capacity(7);
    for _ in 0..7 {
        let t = Instant::now();
        let r = indexer.search("regex:\\.pdf$", LIMIT, false, 0, false);
        re.push(t.elapsed().as_millis());
        assert_eq!(r.len(), LIMIT);
    }
    let re_median = median_ms(&mut re);

    println!("\n=== MacEverything search benchmark (N={N}) ===");
    println!("plain keyword median: {plain_median} ms");
    println!("regex '\\.pdf$' median: {re_median} ms");
    println!("target: plain <10ms, regex <30ms");

    // Generous CI-safe regression gates; tightened toward the real targets in Phase 1.
    assert!(plain_median < 500, "plain search regressed: {plain_median} ms");
    assert!(re_median < 500, "regex search regressed: {re_median} ms");
}
