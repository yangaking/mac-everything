use notify::event::{CreateKind, Event, EventKind, ModifyKind, RemoveKind, RenameMode};
use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use std::path::{Path, PathBuf};
use std::sync::mpsc::channel;
use std::thread;

use crate::indexer::HotEvent;

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
                        for path in event.paths {
                            classify_and_enqueue(event.kind, path);
                        }
                    }
                    Err(e) => println!("watch error: {:?}", e),
                }
            }
        });

        let mut watcher =
            notify::recommended_watcher(tx).expect("Failed to create recommended watcher");

        for path in paths_to_watch {
            watcher
                .watch(path.as_ref(), RecursiveMode::Recursive)
                .expect("Failed to watch path");
        }

        self.watcher = Some(watcher);
    }
}

/// Maps a notify event kind to the appropriate indexer hot event.
///
/// On macOS, FSEvents cannot associate the old and new sides of a rename (see
/// notify's fsevent backend), so a directory move arrives as a Remove for the
/// old path plus a Create for the new path. Handling directory removal as a
/// subtree removal and directory creation as a subtree re-scan therefore
/// reconstructs moves correctly without needing that association.
fn classify_and_enqueue(kind: EventKind, path: PathBuf) {
    use crate::ffi::enqueue_fsevent;

    let event = match kind {
        EventKind::Remove(RemoveKind::Folder) => Some(HotEvent::RemoveDir(path)),
        EventKind::Remove(RemoveKind::File) => Some(HotEvent::Remove(path)),
        EventKind::Remove(_) => {
            // Unknown removal type: remove both the entry and any subtree.
            enqueue_fsevent(HotEvent::Remove(path.clone()));
            Some(HotEvent::RemoveDir(path))
        }
        EventKind::Create(CreateKind::Folder) => Some(HotEvent::AddDir(path)),
        EventKind::Create(CreateKind::File) => Some(HotEvent::Add(path)),
        EventKind::Create(_) => {
            // Unknown create type: add the entry and re-scan any subtree.
            enqueue_fsevent(HotEvent::Add(path.clone()));
            Some(HotEvent::AddDir(path))
        }
        EventKind::Modify(ModifyKind::Name(RenameMode::Any)) | EventKind::Modify(ModifyKind::Name(_)) => {
            // Rename: on macOS this fires independently for old and new paths.
            // If the path still exists and is a directory, re-scan its subtree;
            // otherwise remove the (possibly stale) entry and its subtree.
            if path.is_dir() {
                Some(HotEvent::AddDir(path))
            } else if path.exists() {
                Some(HotEvent::Add(path))
            } else {
                enqueue_fsevent(HotEvent::Remove(path.clone()));
                Some(HotEvent::RemoveDir(path))
            }
        }
        // Content/metadata changes re-stat the entry (updates size/mtime).
        EventKind::Modify(_) | EventKind::Any | EventKind::Access(_) => Some(HotEvent::Add(path)),
        _ => None,
    };

    if let Some(ev) = event {
        enqueue_fsevent(ev);
    }
}
