import AppKit

/// Hosts the terminal at its natural size (columns x rows at the base font) and scales it
/// to fill the window, like KoalaTerm's "fit font": a bigger window means bigger text,
/// never more rows or columns. The terminal never sees a size change, so legacy
/// full-screen applications keep their 80x25 layout.
final class FitContainer: NSView {
    let content: NSView
    private(set) var naturalSize: NSSize

    var fillColor: NSColor = .black {
        didSet { layer?.backgroundColor = fillColor.cgColor }
    }

    init(content: NSView, naturalSize: NSSize) {
        self.content = content
        self.naturalSize = naturalSize
        super.init(frame: NSRect(origin: .zero, size: naturalSize))
        wantsLayer = true
        content.autoresizingMask = []
        content.frame = NSRect(origin: .zero, size: naturalSize)
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var isLayingOut = false

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    // Note: no viewDidChangeBackingProperties override. setBoundsSize itself triggers that
    // callback, and relayouting from it recursed until the stack overflowed (crash on resize).

    private func relayout() {
        guard !isLayingOut,
              naturalSize.width > 0, naturalSize.height > 0,
              frame.width > 0, frame.height > 0 else { return }
        isLayingOut = true
        defer { isLayingOut = false }

        let scale = min(frame.width / naturalSize.width, frame.height / naturalSize.height)
        // Scale the coordinate system: the terminal keeps its frame (and its rows/columns),
        // AppKit draws it larger. Text is re-rendered at the new size, so it stays sharp.
        let target = NSSize(width: frame.width / scale, height: frame.height / scale)
        if abs(bounds.width - target.width) > 0.01 || abs(bounds.height - target.height) > 0.01 {
            setBoundsSize(target)
        }
        let origin = NSPoint(x: ((bounds.width - naturalSize.width) / 2).rounded(),
                             y: ((bounds.height - naturalSize.height) / 2).rounded())
        if content.frame.origin != origin { content.setFrameOrigin(origin) }
        needsDisplay = true
    }
}
