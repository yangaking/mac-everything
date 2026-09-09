// Standalone test for FileBatchOperations pure helpers (no GUI / no printer).
//
// Run:
//   swiftc -module-cache-path /tmp/mecache \
//     MacEverything/FileBatchOperations.swift tests/sandbox/test_batch_ops.swift \
//     -o /tmp/test_batch_ops && /tmp/test_batch_ops
import Foundation

@main
struct BatchOpsTest {
    static func main() {
        var failures = 0

        func check(_ cond: Bool, _ msg: String) {
            if cond {
                print("PASS: \(msg)")
            } else {
                print("FAIL: \(msg)")
                failures += 1
            }
        }

        // --- rangeIndices ---
        check(Array(FileBatchOperations.rangeIndices(from: 0, to: 3)) == [0, 1, 2, 3], "range forward is inclusive")
        check(Array(FileBatchOperations.rangeIndices(from: 3, to: 0)) == [0, 1, 2, 3], "range reverse is order-independent")
        check(Array(FileBatchOperations.rangeIndices(from: 5, to: 5)) == [5], "range single index")

        // --- fileURLs ---
        let urls = FileBatchOperations.fileURLs(for: ["/a/b.txt", "/c/d.pdf"])
        check(urls.count == 2 && urls[0].path == "/a/b.txt" && urls[1].path == "/c/d.pdf", "fileURLs maps paths to file URLs")

        // --- isPrintable ---
        check(FileBatchOperations.isPrintable(path: "/x/a.pdf"), "pdf is printable")
        check(FileBatchOperations.isPrintable(path: "/x/a.PNG"), "png is printable (case-insensitive)")
        check(FileBatchOperations.isPrintable(path: "/x/a.jpg"), "jpg is printable")
        check(FileBatchOperations.isPrintable(path: "/x/a.heic"), "heic is printable")
        check(!FileBatchOperations.isPrintable(path: "/x/a.txt"), "txt is not printable")
        check(!FileBatchOperations.isPrintable(path: "/x/a.mp4"), "mp4 is not printable")
        check(!FileBatchOperations.isPrintable(path: "/x/a.zip"), "zip is not printable")

        if failures == 0 {
            print("ALL PASSED")
        } else {
            print("\(failures) FAILURES")
            exit(1)
        }
    }
}
