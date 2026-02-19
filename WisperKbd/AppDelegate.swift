import Cocoa
import InputMethodKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var server: IMKServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let connectionName = Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String else {
            NSLog("WisperKbd: ERROR — InputMethodConnectionName not found in Info.plist")
            return
        }
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            NSLog("WisperKbd: ERROR — Bundle identifier not found")
            return
        }

        server = IMKServer(name: connectionName, bundleIdentifier: bundleIdentifier)
        NSLog("WisperKbd: IMKServer started — connection: \(connectionName)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSLog("WisperKbd: Application terminating")
    }
}
