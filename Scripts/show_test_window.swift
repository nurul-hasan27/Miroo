import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let secondScreen = NSScreen.screens.first { $0.frame.origin.x >= 2560 } ?? NSScreen.screens.last!
print("Target screen: \(secondScreen.localizedName), frame: \(secondScreen.frame)")

let winWidth: CGFloat = min(secondScreen.frame.width - 60, 580)
let winHeight: CGFloat = min(secondScreen.frame.height - 60, 460)
let rect = NSRect(
    x: secondScreen.frame.origin.x + (secondScreen.frame.width - winWidth) / 2,
    y: secondScreen.frame.origin.y + (secondScreen.frame.height - winHeight) / 2,
    width: winWidth,
    height: winHeight
)

let style: NSWindow.StyleMask = [.titled, .closable, .resizable]
let window = NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
window.title = "Miroo Extended Monitor"
window.backgroundColor = .systemPurple
window.level = .screenSaver
window.collectionBehavior = [.canJoinAllSpaces, .stationary]
window.isOpaque = true

let contentView = NSView(frame: NSRect(x: 0, y: 0, width: winWidth, height: winHeight))
contentView.wantsLayer = true
contentView.layer?.backgroundColor = NSColor.systemIndigo.cgColor

let titleLabel = NSTextField(labelWithString: "📱 Miroo Display")
titleLabel.font = NSFont.boldSystemFont(ofSize: 28)
titleLabel.textColor = .white
titleLabel.alignment = .center
titleLabel.frame = NSRect(x: 20, y: winHeight - 65, width: winWidth - 40, height: 40)
contentView.addSubview(titleLabel)

let subLabel = NSTextField(labelWithString: "Mac M1 ➔ iPhone 11 Live Stream")
subLabel.font = NSFont.systemFont(ofSize: 16, weight: .medium)
subLabel.textColor = .cyan
subLabel.alignment = .center
subLabel.frame = NSRect(x: 20, y: winHeight - 105, width: winWidth - 40, height: 28)
contentView.addSubview(subLabel)

let clockLabel = NSTextField(labelWithString: "00:00:00")
clockLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 42, weight: .bold)
clockLabel.textColor = .systemGreen
clockLabel.alignment = .center
clockLabel.frame = NSRect(x: 20, y: winHeight - 180, width: winWidth - 40, height: 55)
contentView.addSubview(clockLabel)

let infoLabel = NSTextField(labelWithString: """
• Hardware H.264 VideoToolbox
• Metal CVMetalTextureCache
• ScreenCaptureKit 60 FPS
• Dynamic Portrait & Landscape
• Sub-30ms End-to-End Latency
""")
infoLabel.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold)
infoLabel.textColor = .white
infoLabel.alignment = .left
infoLabel.frame = NSRect(x: 40, y: 20, width: winWidth - 80, height: 140)
contentView.addSubview(infoLabel)

window.contentView = contentView
window.makeKeyAndOrderFront(nil)
window.orderFrontRegardless()
app.activate(ignoringOtherApps: true)

let formatter = DateFormatter()
formatter.dateFormat = "HH:mm:ss.SS"

print("Live window active at \(rect). Running for 300 seconds...")

let deadline = Date().addingTimeInterval(300)
while Date() < deadline {
    clockLabel.stringValue = formatter.string(from: Date())
    if let event = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.05), inMode: .default, dequeue: true) {
        app.sendEvent(event)
    }
}
print("Done.")
