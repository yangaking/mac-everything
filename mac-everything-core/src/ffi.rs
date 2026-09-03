use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::OnceLock;
use crate::indexer::Indexer;

// Global singleton for the indexer
static INDEXER: OnceLock<Indexer> = OnceLock::new();

#[repr(C)]
pub struct CSearchResult {
    pub paths: *mut *mut c_char,
    pub count: usize,
}

/// Allocates a `CSearchResult` from Rust-owned strings.
///
/// Uses `into_boxed_slice` so the freed pointer always carries an exact
/// `capacity == len` layout, eliminating the latent UB of reconstructing a
/// `Vec` with an assumed capacity after `shrink_to_fit`.
fn alloc_c_search_result(results: Vec<String>) -> *mut CSearchResult {
    let c_strings: Vec<*mut c_char> = results
        .into_iter()
        .filter_map(|s| CString::new(s).ok())
        .map(|cs| cs.into_raw())
        .collect();

    let boxed: Box<[*mut c_char]> = c_strings.into_boxed_slice();
    let count = boxed.len();
    let paths_ptr = boxed.as_ptr() as *mut *mut c_char;
    std::mem::forget(boxed); // ownership handed to C

    Box::into_raw(Box::new(CSearchResult {
        paths: paths_ptr,
        count,
    }))
}

/// Frees a `CSearchResult` previously returned by `alloc_c_search_result`.
///
/// # Safety
/// `res` must be a pointer obtained from `alloc_c_search_result` and not freed yet.
unsafe fn free_c_search_result(res: *mut CSearchResult) {
    if res.is_null() {
        return;
    }
    let res = Box::from_raw(res);
    // Reconstruct the exact boxed slice (capacity == len), then free each string.
    let slice = std::ptr::slice_from_raw_parts_mut(res.paths, res.count);
    let boxed: Box<[*mut c_char]> = Box::from_raw(slice);
    for &ptr in boxed.iter() {
        if !ptr.is_null() {
            drop(CString::from_raw(ptr));
        }
    }
    // `boxed` deallocates its buffer with the correct layout here.
}

#[no_mangle]
pub extern "C" fn init_engine(root_paths_ptr: *const *const c_char, count: usize) {
    if root_paths_ptr.is_null() || count == 0 {
        return;
    }

    let mut roots = Vec::new();
    let ptrs = unsafe { std::slice::from_raw_parts(root_paths_ptr, count) };
    for &ptr in ptrs {
        if !ptr.is_null() {
            let c_str = unsafe { CStr::from_ptr(ptr) };
            if let Ok(s) = c_str.to_str() {
                roots.push(s.to_string());
            }
        }
    }

    if !roots.is_empty() {
        // Fast cold start: try loading a persisted snapshot; fall back to a full scan.
        let snapshot = crate::persist::default_snapshot_path()
            .and_then(|p| crate::persist::load_indexer(&p).ok());
        let (indexer, was_loaded) = match snapshot {
            Some(idx) => (idx, true),
            None => {
                let idx = Indexer::new();
                idx.scan_directories(&roots);
                (idx, false)
            }
        };
        // The load path does not persist roots; restore them for the rebuild logic.
        *indexer.roots.write().unwrap() = roots.clone();

        // Ignore initialization error if it was already initialized
        if INDEXER.set(indexer).is_ok() {
            // Reconcile offline changes and persist the index in the background.
            // The heavy walk runs without holding locks; only the final swap locks
            // briefly, so searches keep serving the (possibly stale) snapshot until
            // reconciliation completes.
            let reconcile_roots = roots.clone();
            std::thread::spawn(move || {
                if let Some(idx) = INDEXER.get() {
                    if was_loaded {
                        idx.scan_directories(&reconcile_roots);
                    }
                    if let Some(p) = crate::persist::default_snapshot_path() {
                        let _ = crate::persist::save_indexer(idx, &p);
                    }
                }
            });

            // Start FSEventMonitor here in background
            let mut monitor = crate::fsevents::FsEventMonitor::new();
            let monitor_roots = roots.clone();
            std::thread::spawn(move || {
                monitor.start_watching(monitor_roots);
                // Keep the monitor alive on this thread
                loop { std::thread::sleep(std::time::Duration::from_secs(3600)); }
            });

            // Start the debouncer background thread
            std::thread::spawn(|| {
                loop {
                    std::thread::sleep(std::time::Duration::from_millis(500));
                    if let Some(idx) = INDEXER.get() {
                        idx.apply_updates();
                    }
                }
            });

            // Periodic reconciliation: re-scan roots on a slow schedule to catch
            // any drifted/missed events (FSEvents overflow, moves, etc.), then
            // re-persist the corrected index.
            std::thread::spawn(|| {
                loop {
                    std::thread::sleep(std::time::Duration::from_secs(30 * 60));
                    if let Some(idx) = INDEXER.get() {
                        let roots = idx.roots.read().unwrap().clone();
                        idx.scan_directories(&roots);
                        if let Some(p) = crate::persist::default_snapshot_path() {
                            let _ = crate::persist::save_indexer(idx, &p);
                        }
                    }
                }
            });
        }
    }
}

pub fn enqueue_fsevent(event: crate::indexer::HotEvent) {
    if let Some(indexer) = INDEXER.get() {
        indexer.enqueue_event(event);
    }
}

#[no_mangle]
pub extern "C" fn search(query_ptr: *const c_char, limit: usize, enable_path_search: bool, sort_col: u8, sort_asc: bool) -> *mut CSearchResult {
    if query_ptr.is_null() {
        return std::ptr::null_mut();
    }

    let c_str = unsafe { CStr::from_ptr(query_ptr) };
    let query = match c_str.to_str() {
        Ok(q) => q,
        Err(_) => return std::ptr::null_mut(),
    };

    if let Some(indexer) = INDEXER.get() {
        let results = indexer.search(query, limit, enable_path_search, sort_col, sort_asc);
        return alloc_c_search_result(results);
    }
    
    std::ptr::null_mut()
}

#[no_mangle]
pub extern "C" fn free_search_results(res_ptr: *mut CSearchResult) {
    unsafe { free_c_search_result(res_ptr) };
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_c_search_result_round_trip() {
        let paths = vec![
            "/a/b.txt".to_string(),
            "/c/d.pdf".to_string(),
            "/e/f g.jpg".to_string(),
        ];
        let res = alloc_c_search_result(paths.clone());
        assert!(!res.is_null());

        unsafe {
            assert_eq!((*res).count, paths.len());
            let slice = std::slice::from_raw_parts((*res).paths, (*res).count);
            for (i, &p) in slice.iter().enumerate() {
                assert!(!p.is_null());
                assert_eq!(CStr::from_ptr(p).to_str().unwrap(), paths[i]);
            }
            free_c_search_result(res);
        }
    }

    #[test]
    fn test_c_search_result_empty() {
        let res = alloc_c_search_result(Vec::new());
        assert!(!res.is_null());
        unsafe {
            assert_eq!((*res).count, 0);
            free_c_search_result(res);
        }
    }
}
