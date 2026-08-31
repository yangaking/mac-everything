import Foundation

let token = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Prevent App Nap")

print("Activity token acquired. Sleeping for 10 seconds...")
sleep(10)
print("Done.")
