import XCTest
@testable import TerminalUI

final class ANSIParserTests: XCTestCase {
    var parser: ANSIParser!

    override func setUp() {
        parser = ANSIParser()
    }

    func testPlainText() {
        let tokens = parser.parse("Hello, World!")
        XCTAssertEqual(tokens.count, 1)
        if case .text(let text) = tokens[0] {
            XCTAssertEqual(text, "Hello, World!")
        } else {
            XCTFail("Expected text token")
        }
    }

    func testBoldSGR() {
        let tokens = parser.parse("\u{1B}[1mBold")
        XCTAssertTrue(tokens.contains { token in
            if case .sgr(.bold) = token { return true }
            return false
        })
    }

    func testResetSGR() {
        let tokens = parser.parse("\u{1B}[0m")
        XCTAssertTrue(tokens.contains { token in
            if case .sgr(.reset) = token { return true }
            return false
        })
    }

    func testForegroundColor() {
        let tokens = parser.parse("\u{1B}[32mGreen")
        XCTAssertTrue(tokens.contains { token in
            if case .sgr(.foreground(.standard(2))) = token { return true }
            return false
        })
    }

    func test256Color() {
        let tokens = parser.parse("\u{1B}[38;5;196mRed256")
        XCTAssertTrue(tokens.contains { token in
            if case .sgr(.foreground(.palette(196))) = token { return true }
            return false
        })
    }

    func testRGBColor() {
        let tokens = parser.parse("\u{1B}[38;2;255;128;0mOrange")
        XCTAssertTrue(tokens.contains { token in
            if case .sgr(.foreground(.rgb(255, 128, 0))) = token { return true }
            return false
        })
    }

    func testCursorUp() {
        let tokens = parser.parse("\u{1B}[3A")
        XCTAssertTrue(tokens.contains { token in
            if case .cursorMove(.up(3)) = token { return true }
            return false
        })
    }

    func testCursorPosition() {
        let tokens = parser.parse("\u{1B}[10;20H")
        XCTAssertTrue(tokens.contains { token in
            if case .cursorPosition(row: 10, col: 20) = token { return true }
            return false
        })
    }

    func testEraseDisplay() {
        let tokens = parser.parse("\u{1B}[2J")
        XCTAssertTrue(tokens.contains { token in
            if case .eraseDisplay(.all) = token { return true }
            return false
        })
    }

    func testNewline() {
        let tokens = parser.parse("Hello\nWorld")
        XCTAssertTrue(tokens.contains { token in
            if case .newline = token { return true }
            return false
        })
    }

    func testCarriageReturn() {
        let tokens = parser.parse("Hello\rWorld")
        XCTAssertTrue(tokens.contains { token in
            if case .carriageReturn = token { return true }
            return false
        })
    }

    func testSetTitle() {
        let tokens = parser.parse("\u{1B}]2;My Terminal\u{07}")
        XCTAssertTrue(tokens.contains { token in
            if case .setTitle("My Terminal") = token { return true }
            return false
        })
    }

    func testAlternateScreen() {
        let tokens = parser.parse("\u{1B}[?1049h")
        XCTAssertTrue(tokens.contains { token in
            if case .alternateScreen(true) = token { return true }
            return false
        })
    }

    func testCompoundSGR() {
        // ESC[1;32m should produce BOTH bold AND green
        let tokens = parser.parse("\u{1B}[1;32mtest")
        let hasBold = tokens.contains { if case .sgr(.bold) = $0 { return true }; return false }
        let hasGreen = tokens.contains { if case .sgr(.foreground(.standard(2))) = $0 { return true }; return false }
        XCTAssertTrue(hasBold, "Compound SGR should include bold")
        XCTAssertTrue(hasGreen, "Compound SGR should include green foreground")
    }

    func testComplexSequence() {
        // Simulating a typical shell prompt with colors
        let prompt = "\u{1B}[1;32muser@host\u{1B}[0m:\u{1B}[1;34m~/project\u{1B}[0m$ "
        let tokens = parser.parse(prompt)
        XCTAssertGreaterThan(tokens.count, 3)
        // Verify both bold and color are present from ESC[1;32m
        let hasBold = tokens.contains { if case .sgr(.bold) = $0 { return true }; return false }
        let hasGreen = tokens.contains { if case .sgr(.foreground(.standard(2))) = $0 { return true }; return false }
        XCTAssertTrue(hasBold)
        XCTAssertTrue(hasGreen)
    }
}
