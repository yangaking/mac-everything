use notify::{Watcher, RecursiveMode, Event, RecommendedWatcher};
use std::sync::mpsc::channel;
use std::path::Path;
use std::thread;

pub struct FsEventMonitor {
    // We'll keep the watcher alive
    watcher: Option<RecommendedWatcher>,
}

impl FsEventMonitor {
    pub fn new() -> Self {
        Self { watcher: None }
    }

    /// Starts watching the specified paths for changes.
    pub fn start_watching<P: AsRef<Path>>(&mut self, paths_to_watch: Vec<P>) {
        let (tx, rx) = channel();

        // Start a dedicated thread to process events
        thread::spawn(move || {
            for res in rx {
                match res {
                    Ok(event) => {
                        let event: Event = event;
                        // Process all paths in the event
                        for path in event.paths {
                            // Any modification (create, modify, rename, delete) 
                            // will be treated as an "Add", which removes the old record
                            // and tries to parse the new one. If the file is deleted,
                            // parsing fails and it is effectively just removed.
                            crate::ffi::enqueue_fsevent(crate::indexer::HotEvent::Add(path));
                        }
                    },
                    Err(e) => println!("watch error: {:?}", e),
                }
            }
        });

        let mut watcher = notify::recommended_watcher(tx).expect("Failed to create recommended watcher");
        
        for path in paths_to_watch {
            watcher.watch(path.as_ref(), RecursiveMode::Recursive).expect("Failed to watch path");
        }

        self.watcher = Some(watcher);
    }
}
