import Cocoa

class WakeObserver {
    @objc func handleWake(_ notification: Notification) {
        print("Woke up!")
    }
}
