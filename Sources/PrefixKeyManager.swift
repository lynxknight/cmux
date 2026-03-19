import AppKit
import Foundation

/// Protocol for handling PREFIX key actions
@MainActor
protocol PrefixKeyManagerDelegate: AnyObject {
    /// Called when a PREFIX binding action should be executed
    func prefixKeyManager(_ manager: PrefixKeyManager, executeAction action: PrefixKeyManager.PrefixAction)

    /// Called when a raw key event should be sent to the terminal (timeout/double-tap)
    func prefixKeyManager(_ manager: PrefixKeyManager, sendRawKeyToTerminal event: NSEvent)

    /// Called when PREFIX mode state changes (for visual indicator)
    func prefixKeyManager(_ manager: PrefixKeyManager, didEnterPrefixMode entered: Bool)
}

/// Manages tmux-style PREFIX key handling
///
/// State machine:
/// - IDLE: Normal operation, waiting for PREFIX key (Ctrl+A)
/// - PREFIX_PENDING: PREFIX detected, waiting for follow-up key (timeout ~1s)
///   - If valid PREFIX binding key arrives → execute action, return to IDLE
///   - If timeout expires → send raw Ctrl+A to terminal, return to IDLE
///   - If Escape pressed → cancel, return to IDLE
///   - If PREFIX pressed again (double-tap) → send raw Ctrl+A to terminal, return to IDLE
///   - If non-binding key pressed → send Ctrl+A + key to terminal, return to IDLE
@MainActor
final class PrefixKeyManager {

    // MARK: - Types

    enum State: Equatable {
        case idle
        case prefixPending(receivedAt: Date, originalEvent: NSEvent)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle):
                return true
            case (.prefixPending, .prefixPending):
                return true
            default:
                return false
            }
        }
    }

    /// Actions that can be triggered by PREFIX bindings
    enum PrefixAction {
        /// PREFIX+\ → vertical split (side-by-side panes)
        case splitVertical
        /// PREFIX+- → horizontal split (stacked panes)
        case splitHorizontal
        /// PREFIX+z → toggle pane zoom (like tmux resize-pane -Z)
        case toggleZoom
        /// PREFIX+s → open workspace/session switcher
        case openSessionSwitcher
        /// PREFIX+Space → cycle through pane layouts (like tmux next-layout)
        case cycleLayout
        /// PREFIX+q → display pane numbers (like tmux display-panes, base-index=1)
        case displayPanes
        /// PREFIX+x → kill current pane (like tmux kill-pane)
        case killPane
        /// PREFIX+u → toggle unread on focused tab
        case toggleUnread
    }

    // MARK: - Properties

    private var state: State = .idle
    private var timeoutWorkItem: DispatchWorkItem?
    weak var delegate: PrefixKeyManagerDelegate?

    /// Timeout duration in seconds before passing PREFIX through to terminal
    static let timeout: TimeInterval = 1.0

    /// PREFIX key: Ctrl+A
    static let prefixShortcut = StoredShortcut(
        key: "a",
        command: false,
        shift: false,
        option: false,
        control: true
    )

    /// Bindings lookup table: key after PREFIX → action
    private let bindings: [String: PrefixAction] = [
        "\\": .splitVertical,       // PREFIX+\ → side-by-side split
        "-": .splitHorizontal,      // PREFIX+- → stacked split
        "z": .toggleZoom,           // PREFIX+z → toggle zoom
        "s": .openSessionSwitcher,  // PREFIX+s → workspace switcher
        " ": .cycleLayout,          // PREFIX+Space → cycle layouts
        "q": .displayPanes,         // PREFIX+q → display pane numbers
        "x": .killPane,             // PREFIX+x → kill current pane
        "u": .toggleUnread,         // PREFIX+u → toggle unread on focused tab
    ]

    /// Key codes for binding keys (for fallback matching)
    private let bindingKeyCodes: [UInt16: PrefixAction] = [
        42: .splitVertical,   // kVK_ANSI_Backslash
        27: .splitHorizontal, // kVK_ANSI_Minus
        6: .toggleZoom,       // kVK_ANSI_Z
        1: .openSessionSwitcher, // kVK_ANSI_S
        49: .cycleLayout,     // kVK_Space
        12: .displayPanes,    // kVK_ANSI_Q
        7: .killPane,        // kVK_ANSI_X
        32: .toggleUnread,   // kVK_ANSI_U
    ]

    // MARK: - Public API

    /// Process a key event. Returns true if consumed, false to pass through.
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        switch state {
        case .idle:
            return handleIdleState(event: event)
        case .prefixPending(_, let originalEvent):
            return handlePrefixPendingState(event: event, originalEvent: originalEvent)
        }
    }

    /// Returns true if currently waiting for a PREFIX follow-up key
    var isPrefixPending: Bool {
        if case .prefixPending = state {
            return true
        }
        return false
    }

    /// Cancel PREFIX mode without sending any keys
    func cancelPrefixMode() {
        cancelTimeout()
        if case .prefixPending = state {
            state = .idle
            delegate?.prefixKeyManager(self, didEnterPrefixMode: false)
        }
    }

    // MARK: - State Handlers

    private func handleIdleState(event: NSEvent) -> Bool {
        // Check if this is the PREFIX key (Ctrl+A)
        if matchesPrefixKey(event: event) {
            // Enter PREFIX_PENDING state
            state = .prefixPending(receivedAt: Date(), originalEvent: event)
            startTimeout(for: event)
            delegate?.prefixKeyManager(self, didEnterPrefixMode: true)
            return true
        }
        return false
    }

    private func handlePrefixPendingState(event: NSEvent, originalEvent: NSEvent) -> Bool {
        cancelTimeout()

        // Check for double-tap (PREFIX pressed again)
        if matchesPrefixKey(event: event) {
            // Send raw Ctrl+A to terminal
            state = .idle
            delegate?.prefixKeyManager(self, didEnterPrefixMode: false)
            delegate?.prefixKeyManager(self, sendRawKeyToTerminal: originalEvent)
            return true
        }

        // Check for Escape (cancel PREFIX mode)
        if event.keyCode == 53 { // kVK_Escape
            state = .idle
            delegate?.prefixKeyManager(self, didEnterPrefixMode: false)
            return true
        }

        // Check for a PREFIX binding
        if let action = matchPrefixBinding(event: event) {
            state = .idle
            delegate?.prefixKeyManager(self, didEnterPrefixMode: false)
            delegate?.prefixKeyManager(self, executeAction: action)
            return true
        }

        // Unknown key after PREFIX - send both PREFIX and the key through
        state = .idle
        delegate?.prefixKeyManager(self, didEnterPrefixMode: false)
        delegate?.prefixKeyManager(self, sendRawKeyToTerminal: originalEvent)
        // Return false to let the current event pass through normally
        return false
    }

    // MARK: - Key Matching

    private func matchesPrefixKey(event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        guard flags == Self.prefixShortcut.modifierFlags else { return false }

        // Match by character
        let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
        if chars == Self.prefixShortcut.key {
            return true
        }

        // Fallback: match by keyCode for Ctrl+A (keyCode 0 = kVK_ANSI_A)
        if event.keyCode == 0 {
            return true
        }

        return false
    }

    private func matchPrefixBinding(event: NSEvent) -> PrefixAction? {
        // No modifiers should be pressed for binding keys (just the bare key after PREFIX)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        guard flags.isEmpty else { return nil }

        // Try character match first
        let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
        if let action = bindings[chars] {
            return action
        }

        // Fallback: match by keyCode
        if let action = bindingKeyCodes[event.keyCode] {
            return action
        }

        return nil
    }

    // MARK: - Timeout

    private func startTimeout(for originalEvent: NSEvent) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.timeoutExpired(originalEvent: originalEvent)
            }
        }
        timeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout, execute: workItem)
    }

    private func cancelTimeout() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
    }

    private func timeoutExpired(originalEvent: NSEvent) {
        guard case .prefixPending = state else { return }

        // Timeout expired - send raw Ctrl+A to terminal
        state = .idle
        delegate?.prefixKeyManager(self, didEnterPrefixMode: false)
        delegate?.prefixKeyManager(self, sendRawKeyToTerminal: originalEvent)
    }
}
