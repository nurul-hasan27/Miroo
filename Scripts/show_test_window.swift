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

let style: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
let window = NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
window.title = "Miroo Phase 6B Test Monitor"
window.backgroundColor = .windowBackgroundColor
window.isMovableByWindowBackground = true
window.isOpaque = true

let contentView = NSView(frame: NSRect(x: 0, y: 0, width: winWidth, height: winHeight))

// 1. Header label
let titleLabel = NSTextField(labelWithString: "📱 Miroo Trackpad & Scroll Test")
titleLabel.font = NSFont.boldSystemFont(ofSize: 20)
titleLabel.alignment = .center
titleLabel.frame = NSRect(x: 10, y: winHeight - 35, width: winWidth - 20, height: 26)
contentView.addSubview(titleLabel)

// 2. Interactive Click Button
var clickCount = 0
let button = NSButton(title: "Click Me (Clicks: 0)", target: nil, action: nil)
button.bezelStyle = .rounded
button.frame = NSRect(x: 20, y: winHeight - 75, width: 180, height: 32)
contentView.addSubview(button)

// 3. Status label
let statusLabel = NSTextField(labelWithString: "Ready. 1-finger: move/click/drag | 2-finger: scroll | 2-finger tap: right-click")
statusLabel.font = NSFont.systemFont(ofSize: 11)
statusLabel.textColor = .secondaryLabelColor
statusLabel.frame = NSRect(x: 210, y: winHeight - 72, width: winWidth - 220, height: 25)
contentView.addSubview(statusLabel)

// 4. Scrollable Text View
let scrollView = NSScrollView(frame: NSRect(x: 20, y: 20, width: winWidth - 40, height: winHeight - 110))
scrollView.hasVerticalScroller = true
scrollView.hasHorizontalScroller = true
scrollView.autohidesScrollers = false
scrollView.borderType = .bezelBorder

let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: winWidth - 60, height: 2000))
var textContent = "📜 MIROO PHASE 6B INTERACTIVE SCROLL TEST\n"
textContent += "Use two fingers to scroll vertically and horizontally.\n"
textContent += "Perform a stationary two-finger tap to open the context menu (Right Click).\n"
textContent += "=========================================================\n\n"
for i in 1...100 {
    textContent += String(format: "Item Line #%03d: Testing smooth trackpad scrolling on Miroo Extended iPhone\n", i)
}
textView.string = textContent
textView.isEditable = false
textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

scrollView.documentView = textView
contentView.addSubview(scrollView)

window.contentView = contentView
window.makeKeyAndOrderFront(nil)
window.orderFrontRegardless()
app.activate(ignoringOtherApps: true)

class ButtonHandler: NSObject {
    @objc func buttonClicked(_ sender: NSButton) {
        clickCount += 1
        sender.title = "Clicked! Count: \(clickCount)"
        print("[Test Window] Button clicked! Count = \(clickCount)")
    }
}
let handler = ButtonHandler()
button.target = handler
button.action = #selector(ButtonHandler.buttonClicked(_:))

print("Live interactive window active at \(rect). Running for 300 seconds...")

let deadline = Date().addingTimeInterval(300)
while Date() < deadline {
    if let event = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.05), inMode: .default, dequeue: true) {
        app.sendEvent(event)
    }
}
print("Done.")
