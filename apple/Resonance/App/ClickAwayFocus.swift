import AppKit

/// Clicking outside a text field lets go of it, in every window, as on iOS.
/// macOS leaves it focused by default, so Space would keep typing instead of
/// playing. The click still goes on to whatever was clicked.
enum ClickAwayFocus {
    private static var monitor: Any?

    static func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            release(for: event)
            return event
        }
    }

    private static func release(for event: NSEvent) {
        guard let window = event.window,
              let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSView else { return }
        let point = field.convert(event.locationInWindow, from: nil)
        if !field.bounds.contains(point) {
            window.makeFirstResponder(nil)
        }
    }
}
