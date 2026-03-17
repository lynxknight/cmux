import SwiftUI
import AppKit
import Bonsplit

// MARK: - Display Panes Overlay Controller

/// Manages the tmux-style "display-panes" feature (PREFIX+q).
/// Shows numbered indicators on each pane; pressing a number focuses that pane.
@MainActor
final class DisplayPanesOverlayController {
    private var overlayView: DisplayPanesNSOverlayView?
    private var hideWorkItem: DispatchWorkItem?
    private var keyMonitor: Any?
    private var paneInfos: [(paneId: PaneID, frame: CGRect)] = []

    /// Duration before auto-hide (in seconds)
    static let displayDuration: TimeInterval = 2.0

    /// Base index for pane numbering (1 = tmux-style)
    static let baseIndex = 1

    weak var workspace: Workspace?

    deinit {
        hideWorkItem?.cancel()
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    /// Show the pane number overlay
    func show(workspace: Workspace) {
        // Hide any existing overlay first
        hide()

        self.workspace = workspace

        guard let window = NSApp.keyWindow,
              let contentView = window.contentView else {
            #if DEBUG
            dlog("displayPanes.show error=noKeyWindow")
            #endif
            return
        }

        // The terminal portal (WindowTerminalHostView) is installed above contentView
        // in the themeFrame (contentView.superview). We must add our overlay there too,
        // otherwise terminal surfaces render on top of the overlay.
        guard let themeFrame = contentView.superview else {
            #if DEBUG
            dlog("displayPanes.show error=noThemeFrame")
            #endif
            return
        }

        // Get current pane geometries
        let snapshot = workspace.bonsplitController.layoutSnapshot()
        guard !snapshot.panes.isEmpty else {
            #if DEBUG
            dlog("displayPanes.show error=noPanes")
            #endif
            return
        }

        // Convert pane geometries from global (screen) coordinates to themeFrame-local coordinates
        paneInfos = snapshot.panes.compactMap { pane in
            guard let paneId = PaneID(uuidString: pane.paneId) else { return nil }
            let globalFrame = CGRect(
                x: pane.frame.x,
                y: pane.frame.y,
                width: pane.frame.width,
                height: pane.frame.height
            )
            let localFrame = themeFrame.convert(globalFrame, from: nil)
            return (
                paneId: paneId,
                frame: localFrame
            )
        }

        guard !paneInfos.isEmpty else {
            #if DEBUG
            dlog("displayPanes.show error=noPaneIds")
            #endif
            return
        }

        // Create overlay view - using pure AppKit NSView for stability
        let overlay = DisplayPanesNSOverlayView(
            paneFrames: paneInfos.map { $0.frame },
            onDismiss: { [weak self] in
                self?.hide()
            }
        )
        overlay.frame = themeFrame.bounds
        overlay.autoresizingMask = [.width, .height]

        themeFrame.addSubview(overlay, positioned: .above, relativeTo: nil)
        self.overlayView = overlay

        // Start key monitor for number input
        installKeyMonitor()
        scheduleAutoHide()

        #if DEBUG
        dlog("displayPanes.show paneCount=\(paneInfos.count)")
        #endif
    }

    /// Hide the overlay and clean up
    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil

        removeKeyMonitor()

        overlayView?.removeFromSuperview()
        overlayView = nil

        paneInfos = []
        workspace = nil

        #if DEBUG
        dlog("displayPanes.hide")
        #endif
    }

    /// Focus a pane by its display number (1-based)
    private func focusPane(displayNumber: Int) {
        let index = displayNumber - Self.baseIndex
        guard index >= 0, index < paneInfos.count else {
            #if DEBUG
            dlog("displayPanes.focusPane invalid displayNumber=\(displayNumber) paneCount=\(paneInfos.count)")
            #endif
            return
        }

        guard let workspace else {
            hide()
            return
        }

        let paneId = paneInfos[index].paneId

        #if DEBUG
        dlog("displayPanes.focusPane displayNumber=\(displayNumber) paneId=\(paneId.id.uuidString.prefix(8))")
        #endif

        // Capture targets before hiding
        let targetPanelId: UUID? = {
            if let tabId = workspace.bonsplitController.selectedTab(inPane: paneId)?.id {
                return workspace.panelIdFromSurfaceId(tabId)
            }
            return nil
        }()

        // Focus the pane
        workspace.bonsplitController.focusPane(paneId)
        if let panelId = targetPanelId {
            workspace.focusPanel(panelId)
        }

        hide()
    }

    // MARK: - Private

    private func scheduleAutoHide() {
        hideWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.displayDuration, execute: workItem)
    }

    private func installKeyMonitor() {
        removeKeyMonitor()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.overlayView != nil else { return event }

            // Check for number keys 1-9
            let chars = event.charactersIgnoringModifiers ?? ""
            if let digit = chars.first, let number = Int(String(digit)), number >= 1, number <= 9 {
                self.focusPane(displayNumber: number)
                return nil // Consume the event
            }

            // Escape or any other key hides the overlay
            self.hide()
            return nil // Consume the event to prevent it from reaching the terminal
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}

// MARK: - Pure AppKit Overlay View

/// NSView-based overlay that displays numbered indicators on each pane.
/// Uses direct drawing via draw(_:) for maximum reliability.
final class DisplayPanesNSOverlayView: NSView {
    private let paneFrames: [CGRect]
    private let onDismiss: () -> Void

    init(paneFrames: [CGRect], onDismiss: @escaping () -> Void) {
        self.paneFrames = paneFrames
        self.onDismiss = onDismiss
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // Draw semi-transparent overlay background
        NSColor.black.withAlphaComponent(0.3).setFill()
        dirtyRect.fill()

        let font = NSFont.systemFont(ofSize: 64, weight: .bold)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraphStyle
        ]

        for (index, frame) in paneFrames.enumerated() {
            let displayNumber = index + DisplayPanesOverlayController.baseIndex

            let centerX = frame.midX
            let centerY = frame.midY

            // Draw rounded rectangle background
            let boxSize: CGFloat = 100
            let boxRect = CGRect(
                x: centerX - boxSize / 2,
                y: centerY - boxSize / 2,
                width: boxSize,
                height: boxSize
            )
            let boxPath = NSBezierPath(roundedRect: boxRect, xRadius: 16, yRadius: 16)
            NSColor.black.withAlphaComponent(0.75).setFill()
            boxPath.fill()

            // Draw number text
            let text = "\(displayNumber)"
            let textSize = text.size(withAttributes: textAttributes)
            let textRect = CGRect(
                x: centerX - textSize.width / 2,
                y: centerY - textSize.height / 2,
                width: textSize.width,
                height: textSize.height
            )
            text.draw(in: textRect, withAttributes: textAttributes)
        }
    }

    override func mouseDown(with event: NSEvent) {
        onDismiss()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Always claim hit test to block clicks through to content below
        if bounds.contains(point) {
            return self
        }
        return nil
    }

    override var acceptsFirstResponder: Bool { true }
}

// MARK: - PaneID Extension

extension PaneID {
    init?(uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        self.init(id: uuid)
    }
}
