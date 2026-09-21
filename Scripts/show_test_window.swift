import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let secondScreen = NSScreen.screens.first { $0.frame.origin.x >= 2560 } ?? NSScreen.screens.last!
print("Target screen: \(secondScreen.localizedName), frame: \(secondScreen.frame)")

let rect = NSRect(
    x: secondScreen.frame.origin.x + 40,
    y: secondScreen.frame.origin.y + 300,
    width: 505,
    height: 650
)

let style: NSWindow.StyleMask = [.titled, .closable, .resizable]
let window = NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
window.title = "Miroo Extended Monitor"
window.backgroundColor = .systemPurple
window.level = .screenSaver
window.collectionBehavior = [.canJoinAllSpaces, .stationary]
window.isOpaque = true

let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 505, height: 650))
contentView.wantsLayer = true
contentView.layer?.backgroundColor = NSColor.systemIndigo.cgColor

let titleLabel = NSTextField(labelWithString: "📱 Miroo Display")
titleLabel.font = NSFont.boldSystemFont(ofSize: 32)
titleLabel.textColor = .white
titleLabel.alignment = .center
titleLabel.frame = NSRect(x: 20, y: 550, width: 465, height: 50)
contentView.addSubview(titleLabel)

let subLabel = NSTextField(labelWithString: "Mac M1 ➔ iPhone 11 Live Stream")
subLabel.font = NSFont.systemFont(ofSize: 18, weight: .medium)
subLabel.textColor = .cyan
subLabel.alignment = .center
subLabel.frame = NSRect(x: 20, y: 500, width: 465, height: 30)
contentView.addSubview(subLabel)

let clockLabel = NSTextField(labelWithString: "00:00:00")
clockLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 48, weight: .bold)
clockLabel.textColor = .systemGreen
clockLabel.alignment = .center
clockLabel.frame = NSRect(x: 20, y: 380, width: 465, height: 65)
contentView.addSubview(clockLabel)

let infoLabel = NSTextField(labelWithString: """
• Hardware H.264 VideoToolbox
• Metal CVMetalTextureCache
• ScreenCaptureKit 60 FPS
• Low-latency Bonjour Transport
• Sub-30ms End-to-End Latency
""")
infoLabel.font = NSFont.monospacedSystemFont(ofSize: 16, weight: .semibold)
infoLabel.textColor = .white
infoLabel.alignment = .left
infoLabel.frame = NSRect(x: 40, y: 120, width: 425, height: 200)
contentView.addSubview(infoLabel)

window.contentView = contentView
window.makeKeyAndOrderFront(nil)
window.orderFrontRegardless()
app.activate(ignoringOtherApps: true)

let formatter = DateFormatter()
formatter.dateFormat = "HH:mm:ss.SS"

print("Live window active at \(rect). Running for 60 seconds...")

let deadline = Date().addingTimeInterval(60)
while Date() < deadline {
    clockLabel.stringValue = formatter.string(from: Date())
    if let event = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.05), inMode: .default, dequeue: true) {
        app.sendEvent(event)
    }
}
print("Done.")
