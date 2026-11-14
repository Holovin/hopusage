import AppKit
import XCTest
@testable import OpenUsage

/// ⌘Z and ⌘, match the character typed, so they follow the keyboard layout; Esc and Return match the key.
final class PopoverKeyLayoutTests: XCTestCase {
    private func key(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags, _ characters: String?) -> PopoverKeyReader.Key? {
        PopoverKeyReader.key(keyCode: keyCode, modifiers: modifiers, characters: characters)
    }

    func testUndoFollowsTheLayout() {
        // On QWERTZ the Z key sits where QWERTY has Y (key code 16); QWERTY's Z position (6) types "y".
        XCTAssertEqual(key(16, [.command], "z"), .undo)
        XCTAssertNil(key(6, [.command], "y"))
        XCTAssertEqual(key(6, [.command], "z"), .undo)
        XCTAssertEqual(key(6, [.command, .capsLock], "Z"), .undo)
    }

    func testSettingsFollowsTheLayout() {
        XCTAssertEqual(key(43, [.command], ","), .settings)
        XCTAssertEqual(key(13, [.command], ","), .settings)
        XCTAssertNil(key(43, [.command], "w"))
    }

    func testOnlyThePlainShortcutCounts() {
        XCTAssertNil(key(6, [], "z"))
        XCTAssertNil(key(6, [.command, .shift], "z"))
        XCTAssertNil(key(43, [], ","))
        XCTAssertNil(key(43, [.command, .option], ","))
    }

    func testEscapeAndReturnMatchTheKey() {
        XCTAssertEqual(key(53, [], "\u{1B}"), .escape)
        XCTAssertEqual(key(53, [.command], nil), .escape)
        XCTAssertEqual(key(36, [], "\r"), .return)
        XCTAssertNil(key(36, [.command], "\r"))
    }
}
