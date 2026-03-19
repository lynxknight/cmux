import AppKit
import Foundation

/// Manages loading and hot-reloading of `~/.cmux.conf` (JSON format).
///
/// Example config:
/// ```json
/// {
///   "prefix": {
///     "key": "ctrl+a",
///     "timeout": 1.0,
///     "bindings": {
///       "\\": "split-vertical",
///       "-": "split-horizontal",
///       "z": "toggle-zoom",
///       "s": "session-switcher",
///       "space": "cycle-layout",
///       "q": "display-panes",
///       "x": "kill-pane",
///       "u": "toggle-unread"
///     }
///   },
///   "keybindings": {
///     "toggle-sidebar": "cmd+b",
///     "new-workspace": "cmd+n",
///     "split-right": "cmd+d"
///   }
/// }
/// ```
@MainActor
final class CmuxConfig: ObservableObject {
    static let shared = CmuxConfig()

    static let configDidReload = Notification.Name("com.cmuxterm.config.didReload")

    /// Parsed prefix config (nil = use defaults)
    @Published private(set) var prefixConfig: PrefixConfig?

    /// Parsed keybinding overrides (action name → shortcut)
    @Published private(set) var keybindings: [String: StoredShortcut] = [:]

    /// Last load error (nil = success or no file)
    @Published private(set) var lastError: String?

    /// Path to the config file
    private(set) var configPath: String

    private init() {
        self.configPath = Self.defaultConfigPath()
        load()
    }

    // MARK: - Config Path

    static func defaultConfigPath() -> String {
        NSHomeDirectory() + "/.cmux.conf"
    }

    // MARK: - Loading

    func load() {
        let path = configPath
        let fm = FileManager.default

        guard fm.fileExists(atPath: path) else {
            prefixConfig = nil
            keybindings = [:]
            lastError = nil
            return
        }

        guard let data = fm.contents(atPath: path) else {
            lastError = "Could not read \(path)"
            return
        }

        guard !data.isEmpty else {
            prefixConfig = nil
            keybindings = [:]
            lastError = nil
            return
        }

        do {
            let parsed = try Self.parse(data)
            prefixConfig = parsed.prefix
            keybindings = parsed.keybindings
            lastError = nil
        } catch {
            lastError = "Config parse error: \(error.localizedDescription)"
        }

        NotificationCenter.default.post(name: Self.configDidReload, object: nil)
    }

    func reload() {
        load()
#if DEBUG
        if let error = lastError {
            dlog("config.reload error=\(error)")
        } else {
            let prefixBindingCount = prefixConfig?.bindings.count ?? 0
            dlog("config.reload ok prefixBindings=\(prefixBindingCount) keybindings=\(keybindings.count)")
        }
#endif
    }

    // MARK: - Parsed Types

    struct PrefixConfig {
        var key: StoredShortcut?
        var timeout: TimeInterval?
        var bindings: [String: PrefixKeyManager.PrefixAction]
    }

    struct ParsedConfig {
        var prefix: PrefixConfig?
        var keybindings: [String: StoredShortcut]
    }

    // MARK: - Parsing

    static func parse(_ data: Data) throws -> ParsedConfig {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigError.invalidFormat("Root must be a JSON object")
        }

        let prefix: PrefixConfig? = try {
            guard let prefixDict = json["prefix"] as? [String: Any] else { return nil }
            return try parsePrefixConfig(prefixDict)
        }()

        let keybindings: [String: StoredShortcut] = try {
            guard let dict = json["keybindings"] as? [String: String] else { return [:] }
            return try parseKeybindings(dict)
        }()

        return ParsedConfig(prefix: prefix, keybindings: keybindings)
    }

    private static func parsePrefixConfig(_ dict: [String: Any]) throws -> PrefixConfig {
        let key: StoredShortcut? = try {
            guard let keyStr = dict["key"] as? String else { return nil }
            return try parseShortcutString(keyStr)
        }()

        let timeout: TimeInterval? = dict["timeout"] as? TimeInterval

        let bindings: [String: PrefixKeyManager.PrefixAction] = try {
            guard let bindingsDict = dict["bindings"] as? [String: String] else { return [:] }
            var result: [String: PrefixKeyManager.PrefixAction] = [:]
            for (key, actionName) in bindingsDict {
                guard let action = prefixActionFromString(actionName) else {
                    throw ConfigError.unknownAction("Unknown prefix action: \(actionName)")
                }
                let normalizedKey = normalizePrefixBindingKey(key)
                result[normalizedKey] = action
            }
            return result
        }()

        return PrefixConfig(key: key, timeout: timeout, bindings: bindings)
    }

    private static func parseKeybindings(_ dict: [String: String]) throws -> [String: StoredShortcut] {
        var result: [String: StoredShortcut] = [:]
        for (actionName, shortcutStr) in dict {
            guard keybindingActionFromString(actionName) != nil else {
                throw ConfigError.unknownAction("Unknown keybinding action: \(actionName)")
            }
            result[actionName] = try parseShortcutString(shortcutStr)
        }
        return result
    }

    // MARK: - Shortcut String Parsing

    /// Parses a shortcut string like "cmd+shift+u", "ctrl+a", "cmd+opt+left"
    static func parseShortcutString(_ str: String) throws -> StoredShortcut {
        let parts = str.lowercased().split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else {
            throw ConfigError.invalidShortcut("Empty shortcut string")
        }

        var cmd = false
        var shift = false
        var opt = false
        var ctrl = false
        var key: String?

        for part in parts {
            switch part {
            case "cmd", "command", "super":
                cmd = true
            case "shift":
                shift = true
            case "opt", "option", "alt":
                opt = true
            case "ctrl", "control":
                ctrl = true
            default:
                if key != nil {
                    throw ConfigError.invalidShortcut("Multiple keys in shortcut: \(str)")
                }
                key = normalizeKeyName(part)
            }
        }

        guard let resolvedKey = key else {
            throw ConfigError.invalidShortcut("No key in shortcut: \(str)")
        }

        return StoredShortcut(key: resolvedKey, command: cmd, shift: shift, option: opt, control: ctrl)
    }

    /// Normalizes key names to the format StoredShortcut expects
    static func normalizeKeyName(_ name: String) -> String {
        switch name {
        case "space": return " "
        case "tab": return "\t"
        case "return", "enter": return "\r"
        case "escape", "esc": return "\u{1B}"
        case "left": return "←"
        case "right": return "→"
        case "up": return "↑"
        case "down": return "↓"
        case "backslash": return "\\"
        case "minus", "dash": return "-"
        case "plus": return "+"
        case "equals", "equal": return "="
        case "delete", "backspace": return "\u{7F}"
        default: return name
        }
    }

    /// Normalizes a prefix binding key string (used as dictionary key)
    static func normalizePrefixBindingKey(_ key: String) -> String {
        let lower = key.lowercased()
        switch lower {
        case "space": return " "
        case "backslash": return "\\"
        case "minus", "dash": return "-"
        case "tab": return "\t"
        default: return lower
        }
    }

    // MARK: - Action Name Mapping

    static func prefixActionFromString(_ name: String) -> PrefixKeyManager.PrefixAction? {
        switch name {
        case "split-vertical": return .splitVertical
        case "split-horizontal": return .splitHorizontal
        case "toggle-zoom": return .toggleZoom
        case "session-switcher": return .openSessionSwitcher
        case "cycle-layout": return .cycleLayout
        case "display-panes": return .displayPanes
        case "kill-pane": return .killPane
        case "toggle-unread": return .toggleUnread
        case "reload-config": return .reloadConfig
        default: return nil
        }
    }

    static let prefixActionNames: [PrefixKeyManager.PrefixAction: String] = [
        .splitVertical: "split-vertical",
        .splitHorizontal: "split-horizontal",
        .toggleZoom: "toggle-zoom",
        .openSessionSwitcher: "session-switcher",
        .cycleLayout: "cycle-layout",
        .displayPanes: "display-panes",
        .killPane: "kill-pane",
        .toggleUnread: "toggle-unread",
        .reloadConfig: "reload-config",
    ]

    static func keybindingActionFromString(_ name: String) -> KeyboardShortcutSettings.Action? {
        switch name {
        case "toggle-sidebar": return .toggleSidebar
        case "new-workspace": return .newTab
        case "new-window": return .newWindow
        case "close-window": return .closeWindow
        case "open-folder": return .openFolder
        case "send-feedback": return .sendFeedback
        case "show-notifications": return .showNotifications
        case "jump-to-unread": return .jumpToUnread
        case "flash-panel": return .triggerFlash
        case "next-surface": return .nextSurface
        case "prev-surface": return .prevSurface
        case "next-workspace": return .nextSidebarTab
        case "prev-workspace": return .prevSidebarTab
        case "rename-tab": return .renameTab
        case "rename-workspace": return .renameWorkspace
        case "close-workspace": return .closeWorkspace
        case "new-surface": return .newSurface
        case "toggle-copy-mode": return .toggleTerminalCopyMode
        case "focus-left": return .focusLeft
        case "focus-right": return .focusRight
        case "focus-up": return .focusUp
        case "focus-down": return .focusDown
        case "split-right": return .splitRight
        case "split-down": return .splitDown
        case "toggle-zoom": return .toggleSplitZoom
        case "split-browser-right": return .splitBrowserRight
        case "split-browser-down": return .splitBrowserDown
        case "open-browser": return .openBrowser
        case "toggle-browser-devtools": return .toggleBrowserDeveloperTools
        case "show-browser-console": return .showBrowserJavaScriptConsole
        default: return nil
        }
    }

    static let keybindingActionNames: [KeyboardShortcutSettings.Action: String] = {
        var map: [KeyboardShortcutSettings.Action: String] = [:]
        let allNames = [
            "toggle-sidebar", "new-workspace", "new-window", "close-window", "open-folder",
            "send-feedback", "show-notifications", "jump-to-unread", "flash-panel",
            "next-surface", "prev-surface", "next-workspace", "prev-workspace",
            "rename-tab", "rename-workspace", "close-workspace", "new-surface",
            "toggle-copy-mode", "focus-left", "focus-right", "focus-up", "focus-down",
            "split-right", "split-down", "toggle-zoom", "split-browser-right",
            "split-browser-down", "open-browser", "toggle-browser-devtools",
            "show-browser-console",
        ]
        for name in allNames {
            if let action = keybindingActionFromString(name) {
                map[action] = name
            }
        }
        return map
    }()

    // MARK: - Query Helpers

    /// Returns the config-file override for a keybinding action, or nil to use the default/UserDefaults value.
    func shortcutOverride(for action: KeyboardShortcutSettings.Action) -> StoredShortcut? {
        guard let name = Self.keybindingActionNames[action] else { return nil }
        return keybindings[name]
    }

    // MARK: - Errors

    enum ConfigError: LocalizedError {
        case invalidFormat(String)
        case invalidShortcut(String)
        case unknownAction(String)

        var errorDescription: String? {
            switch self {
            case .invalidFormat(let msg): return msg
            case .invalidShortcut(let msg): return msg
            case .unknownAction(let msg): return msg
            }
        }
    }
}
