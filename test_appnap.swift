import Foundation
let token = ProcessInfo.processInfo.beginActivity(
    options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
    reason: "test"
)
print("Success")
