// Two-window fixture for the isolated 0.3.3 stream lane (workspace-lane.py
// --streams). It never activates itself (accessory policy, launched by exec,
// not LaunchServices), orders its windows to the BACK so they sit behind the
// person's work, and only changes its own labels. stdin "closeB" closes
// window B so the lane can watch one stream fail while the other runs.
import AppKit

final class LaneFixture: NSObject, NSApplicationDelegate {
    var windows: [NSWindow] = []
    var labels: [NSTextField] = []
    var tick = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        for (index, name) in ["A", "B"].enumerated() {
            let window = NSWindow(
                contentRect: NSRect(x: 24 + index * 196, y: 24, width: 180, height: 110),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "CMM Lane \(name)"
            window.isReleasedWhenClosed = false
            let label = NSTextField(labelWithString: name)
            label.frame = NSRect(x: 10, y: 30, width: 160, height: 40)
            label.font = .monospacedDigitSystemFont(ofSize: 26, weight: .bold)
            window.contentView?.addSubview(label)
            labels.append(label)
            windows.append(window)
            window.orderBack(nil)
        }
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.tick += 1
            for (index, label) in self.labels.enumerated() {
                label.stringValue = "\(index == 0 ? "A" : "B") \(self.tick)"
            }
        }
        print("WINDOWS " + windows.map { String($0.windowNumber) }.joined(separator: " "))
        fflush(stdout)
        let main = DispatchQueue.main
        DispatchQueue.global().async {
            while let line = readLine() {
                if line == "closeB" { main.async { self.windows[1].close() } }
            }
        }
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let fixture = LaneFixture()
application.delegate = fixture
application.run()
