// CMM Computer Use Fixture — a rehearsal application for live checks.
//
// Deliberately boring and data-free: one window, a counter, an editable text
// field, and a button that recreates the window. It exists so that an action
// pipeline can be measured on something whose entire state is knowable, and so
// that no personal application is ever touched.
//
// It writes its own state to a file after every change, so a test can verify
// the EFFECT independently of the accessibility tree it is reading: the same
// fact observed through two channels is evidence; observed through one is a
// loop.
//
// Launch it with `open -g` so it appears WITHOUT taking focus: the whole point
// is to act on it while another application stays frontmost.

import AppKit
import Foundation

final class FixtureController: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    private var window: NSWindow?
    private var counterLabel: NSTextField?
    private var field: NSTextField?
    private var counter = 0 {
        didSet { refreshLabels() }
    }
    private var textValue = ""
    private let statePath: String = {
        ProcessInfo.processInfo.environment["CMM_CU_FIXTURE_STATE"]
            ?? (NSTemporaryDirectory() + "cmm-cu-fixture-state.json")
    }()
    private var pollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeWindow()
        NSApp.setActivationPolicy(.regular)
        // Poll the field: AXSetAttributeValue does not always route through
        // controlTextDidChange, and the state file must reflect reality either
        // way. 100 ms is far below the test's own step cadence.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.pollField()
        }
        writeState(reason: "launched")
    }

    private func makeWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "CMM Computer Use Fixture"
        window.isReleasedWhenClosed = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 260))

        let title = NSTextField(labelWithString: "CMM Computer Use Fixture")
        title.frame = NSRect(x: 20, y: 214, width: 380, height: 22)
        title.font = NSFont.boldSystemFont(ofSize: 15)
        title.setAccessibilityIdentifier("titulo")
        content.addSubview(title)

        let counter = NSTextField(labelWithString: "contador: 0")
        counter.frame = NSRect(x: 20, y: 178, width: 380, height: 22)
        counter.setAccessibilityIdentifier("contador")
        content.addSubview(counter)
        counterLabel = counter

        let button = NSButton(title: "Incrementar", target: self, action: #selector(increment))
        button.frame = NSRect(x: 20, y: 132, width: 140, height: 32)
        button.bezelStyle = .rounded
        button.setAccessibilityIdentifier("incrementar")
        content.addSubview(button)

        let recreate = NSButton(title: "Recrear ventana", target: self, action: #selector(recreateWindow))
        recreate.frame = NSRect(x: 172, y: 132, width: 160, height: 32)
        recreate.bezelStyle = .rounded
        recreate.setAccessibilityIdentifier("recrear")
        content.addSubview(recreate)

        let label = NSTextField(labelWithString: "campo:")
        label.frame = NSRect(x: 20, y: 88, width: 60, height: 22)
        content.addSubview(label)

        let field = NSTextField(frame: NSRect(x: 84, y: 86, width: 316, height: 24))
        field.stringValue = ""
        field.placeholderString = "texto de ensayo"
        field.delegate = self
        field.setAccessibilityIdentifier("campo")
        content.addSubview(field)
        self.field = field

        let footer = NSTextField(labelWithString: "estado: listo")
        footer.frame = NSRect(x: 20, y: 30, width: 380, height: 22)
        footer.setAccessibilityIdentifier("estado")
        content.addSubview(footer)

        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    @objc private func increment() {
        counter += 1
        writeState(reason: "increment")
    }

    @objc private func recreateWindow() {
        // Replaces the window (and every AX element in it) while the process
        // stays alive: the case a stale element handle must not survive.
        window?.orderOut(nil)
        window = nil
        makeWindow()
        writeState(reason: "recreate_window")
    }

    private func pollField() {
        guard let field else { return }
        let current = field.stringValue
        if current != textValue {
            textValue = current
            writeState(reason: "text")
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        pollField()
    }

    private func refreshLabels() {
        counterLabel?.stringValue = "contador: \(counter)"
    }

    private func writeState(reason: String) {
        let payload: [String: Any] = [
            "counter": counter,
            "text": textValue,
            "reason": reason,
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "updated_at": Date().timeIntervalSince1970,
            "window_title": window?.title ?? "",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: statePath), options: .atomic)
    }
}

let app = NSApplication.shared
let controller = FixtureController()
app.delegate = controller
app.run()
