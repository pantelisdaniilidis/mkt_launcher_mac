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

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        relayout()
    }

    private func relayout() {
        guard naturalSize.width > 0, naturalSize.height > 0,
              frame.width > 0, frame.height > 0 else { return }
        let scale = min(frame.width / naturalSize.width, frame.height / naturalSize.height)
        // Scale the coordinate system: the terminal keeps its frame (and its rows/columns),
        // AppKit draws it larger. Text is re-rendered at the new size, so it stays sharp.
        setBoundsSize(NSSize(width: frame.width / scale, height: frame.height / scale))
        content.setFrameOrigin(NSPoint(x: ((bounds.width - naturalSize.width) / 2).rounded(),
                                       y: ((bounds.height - naturalSize.height) / 2).rounded()))
        needsDisplay = true
        content.needsDisplay = true
    }
}
