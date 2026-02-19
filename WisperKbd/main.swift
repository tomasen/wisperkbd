import Cocoa
import InputMethodKit

// Custom NSApplication subclass to control IMKit lifecycle
class WisperApplication: NSApplication {
    private let appDelegate = AppDelegate()

    override init() {
        super.init()
        self.delegate = appDelegate
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// Launch the app
autoreleasepool {
    let app = WisperApplication.shared
    NSLog("WisperKbd: Starting application")
    app.run()
}
