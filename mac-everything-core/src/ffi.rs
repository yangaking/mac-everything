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

#[no_mangle]
pub extern "C" fn init_engine(root_path_ptr: *const c_char) {
    if root_path_ptr.is_null() {
        return;
    }

    let c_str = unsafe { CStr::from_ptr(root_path_ptr) };
    if let Ok(root_path) = c_str.to_str() {
        let indexer = Indexer::new();
        // Perform initial scan
        indexer.scan_directory(root_path);
        
        // TODO: Start FSEventMonitor here in background
        
        // Ignore initialization error if it was already initialized
        let _ = INDEXER.set(indexer);
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
        
        // Convert to C strings
        let mut c_strings: Vec<*mut c_char> = results
            .into_iter()
            .filter_map(|s| CString::new(s).ok())
            .map(|cs| cs.into_raw())
            .collect();
            
        let count = c_strings.len();
        c_strings.shrink_to_fit();
        let paths_ptr = c_strings.as_mut_ptr();
        std::mem::forget(c_strings); // Hand over memory management to C
        
        let result_struct = Box::new(CSearchResult {
            paths: paths_ptr,
            count,
        });
        
        return Box::into_raw(result_struct);
    }
    
    std::ptr::null_mut()
}

#[no_mangle]
pub extern "C" fn free_search_results(res_ptr: *mut CSearchResult) {
    if res_ptr.is_null() {
        return;
    }
    
    unsafe {
        let res = Box::from_raw(res_ptr);
        // Free the array of strings
        let paths_vec = Vec::from_raw_parts(res.paths, res.count, res.count);
        for &ptr in paths_vec.iter() {
            if !ptr.is_null() {
                let _ = CString::from_raw(ptr); // Drops the CString
            }
        }
        // res Box is dropped here
    }
}
