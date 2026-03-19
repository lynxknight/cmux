import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class CmuxConfigParseShortcutTests: XCTestCase {
    func testParseSimpleModifierPlusKey() throws {
        let shortcut = try CmuxConfig.parseShortcutString("cmd+b")
        XCTAssertEqual(shortcut.key, "b")
        XCTAssertTrue(shortcut.command)
        XCTAssertFalse(shortcut.shift)
        XCTAssertFalse(shortcut.option)
        XCTAssertFalse(shortcut.control)
    }

    func testParseMultipleModifiers() throws {
        let shortcut = try CmuxConfig.parseShortcutString("cmd+shift+u")
        XCTAssertEqual(shortcut.key, "u")
        XCTAssertTrue(shortcut.command)
        XCTAssertTrue(shortcut.shift)
        XCTAssertFalse(shortcut.option)
        XCTAssertFalse(shortcut.control)
    }

    func testParseCtrlKey() throws {
        let shortcut = try CmuxConfig.parseShortcutString("ctrl+a")
        XCTAssertEqual(shortcut.key, "a")
        XCTAssertTrue(shortcut.control)
        XCTAssertFalse(shortcut.command)
    }

    func testParseOptionAlt() throws {
        let shortcutOpt = try CmuxConfig.parseShortcutString("cmd+opt+left")
        XCTAssertEqual(shortcutOpt.key, "←")
        XCTAssertTrue(shortcutOpt.command)
        XCTAssertTrue(shortcutOpt.option)

        let shortcutAlt = try CmuxConfig.parseShortcutString("cmd+alt+right")
        XCTAssertEqual(shortcutAlt.key, "→")
        XCTAssertTrue(shortcutAlt.option)
    }

    func testParseSpecialKeys() throws {
        XCTAssertEqual(try CmuxConfig.parseShortcutString("cmd+space").key, " ")
        XCTAssertEqual(try CmuxConfig.parseShortcutString("cmd+tab").key, "\t")
        XCTAssertEqual(try CmuxConfig.parseShortcutString("cmd+return").key, "\r")
        XCTAssertEqual(try CmuxConfig.parseShortcutString("cmd+enter").key, "\r")
        XCTAssertEqual(try CmuxConfig.parseShortcutString("cmd+up").key, "↑")
        XCTAssertEqual(try CmuxConfig.parseShortcutString("cmd+down").key, "↓")
        XCTAssertEqual(try CmuxConfig.parseShortcutString("cmd+backslash").key, "\\")
    }

    func testParseCaseInsensitive() throws {
        let shortcut = try CmuxConfig.parseShortcutString("CMD+SHIFT+N")
        XCTAssertTrue(shortcut.command)
        XCTAssertTrue(shortcut.shift)
        XCTAssertEqual(shortcut.key, "n")
    }

    func testParseEmptyStringThrows() {
        XCTAssertThrowsError(try CmuxConfig.parseShortcutString(""))
    }

    func testParseNoKeyThrows() {
        XCTAssertThrowsError(try CmuxConfig.parseShortcutString("cmd+shift"))
    }

    func testParseMultipleKeysThrows() {
        XCTAssertThrowsError(try CmuxConfig.parseShortcutString("cmd+a+b"))
    }

    func testParseModifierAliases() throws {
        let s1 = try CmuxConfig.parseShortcutString("command+a")
        XCTAssertTrue(s1.command)

        let s2 = try CmuxConfig.parseShortcutString("control+a")
        XCTAssertTrue(s2.control)

        let s3 = try CmuxConfig.parseShortcutString("option+a")
        XCTAssertTrue(s3.option)

        let s4 = try CmuxConfig.parseShortcutString("super+a")
        XCTAssertTrue(s4.command)
    }
}

final class CmuxConfigParseTests: XCTestCase {
    func testParseEmptyConfig() throws {
        let data = "{}".data(using: .utf8)!
        let config = try CmuxConfig.parse(data)
        XCTAssertNil(config.prefix)
        XCTAssertTrue(config.keybindings.isEmpty)
    }

    func testParsePrefixBindings() throws {
        let json = """
        {
            "prefix": {
                "bindings": {
                    "\\\\": "split-vertical",
                    "-": "split-horizontal",
                    "z": "toggle-zoom",
                    "u": "toggle-unread"
                }
            }
        }
        """
        let config = try CmuxConfig.parse(json.data(using: .utf8)!)
        XCTAssertNotNil(config.prefix)
        XCTAssertEqual(config.prefix?.bindings.count, 4)
        XCTAssertEqual(config.prefix?.bindings["\\"], .splitVertical)
        XCTAssertEqual(config.prefix?.bindings["-"], .splitHorizontal)
        XCTAssertEqual(config.prefix?.bindings["z"], .toggleZoom)
        XCTAssertEqual(config.prefix?.bindings["u"], .toggleUnread)
    }

    func testParsePrefixKey() throws {
        let json = """
        {
            "prefix": {
                "key": "ctrl+b"
            }
        }
        """
        let config = try CmuxConfig.parse(json.data(using: .utf8)!)
        XCTAssertEqual(config.prefix?.key?.key, "b")
        XCTAssertTrue(config.prefix?.key?.control ?? false)
    }

    func testParsePrefixTimeout() throws {
        let json = """
        {
            "prefix": {
                "timeout": 2.5
            }
        }
        """
        let config = try CmuxConfig.parse(json.data(using: .utf8)!)
        XCTAssertEqual(config.prefix?.timeout, 2.5)
    }

    func testParseKeybindings() throws {
        let json = """
        {
            "keybindings": {
                "toggle-sidebar": "cmd+b",
                "split-right": "cmd+d",
                "focus-left": "cmd+opt+left"
            }
        }
        """
        let config = try CmuxConfig.parse(json.data(using: .utf8)!)
        XCTAssertEqual(config.keybindings.count, 3)

        let sidebar = config.keybindings["toggle-sidebar"]
        XCTAssertEqual(sidebar?.key, "b")
        XCTAssertTrue(sidebar?.command ?? false)

        let focusLeft = config.keybindings["focus-left"]
        XCTAssertEqual(focusLeft?.key, "←")
        XCTAssertTrue(focusLeft?.command ?? false)
        XCTAssertTrue(focusLeft?.option ?? false)
    }

    func testParseUnknownPrefixActionThrows() {
        let json = """
        {
            "prefix": {
                "bindings": {
                    "z": "nonexistent-action"
                }
            }
        }
        """
        XCTAssertThrowsError(try CmuxConfig.parse(json.data(using: .utf8)!))
    }

    func testParseUnknownKeybindingActionThrows() {
        let json = """
        {
            "keybindings": {
                "nonexistent-action": "cmd+x"
            }
        }
        """
        XCTAssertThrowsError(try CmuxConfig.parse(json.data(using: .utf8)!))
    }

    func testParseSpaceBindingKey() throws {
        let json = """
        {
            "prefix": {
                "bindings": {
                    "space": "cycle-layout"
                }
            }
        }
        """
        let config = try CmuxConfig.parse(json.data(using: .utf8)!)
        XCTAssertEqual(config.prefix?.bindings[" "], .cycleLayout)
    }

    func testParsePrefixActionNameRoundTrip() {
        for (action, name) in CmuxConfig.prefixActionNames {
            let parsed = CmuxConfig.prefixActionFromString(name)
            XCTAssertEqual(parsed, action, "Round-trip failed for \(name)")
        }
    }

    func testParseKeybindingActionNameRoundTrip() {
        for (action, name) in CmuxConfig.keybindingActionNames {
            let parsed = CmuxConfig.keybindingActionFromString(name)
            XCTAssertEqual(parsed, action, "Round-trip failed for \(name)")
        }
    }
}
