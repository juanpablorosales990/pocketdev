import Foundation
import SwiftUI

/// Terminal character cell with attributes
public struct TerminalCell: Equatable {
    public var character: Character
    public var foreground: TerminalColor
    public var background: TerminalColor
    public var bold: Bool
    public var dim: Bool
    public var italic: Bool
    public var underline: Bool
    public var blink: Bool
    public var inverse: Bool
    public var strikethrough: Bool

    public static let empty = TerminalCell(
        character: " ",
        foreground: .default,
        background: .default,
        bold: false, dim: false, italic: false, underline: false,
        blink: false, inverse: false, strikethrough: false
    )
}

public enum TerminalColor: Equatable {
    case `default`
    case standard(UInt8)
    case bright(UInt8)
    case palette(UInt8)
    case rgb(UInt8, UInt8, UInt8)

    public var swiftUIColor: Color {
        switch self {
        case .default: return .primary
        case .standard(let n):
            return Self.standardColors[Int(n)]
        case .bright(let n):
            return Self.brightColors[Int(n)]
        case .palette(let n):
            return Self.paletteColor(n)
        case .rgb(let r, let g, let b):
            return Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
        }
    }

    private static let standardColors: [Color] = [
        Color(red: 0, green: 0, blue: 0),         // 0 Black
        Color(red: 0.8, green: 0.2, blue: 0.2),   // 1 Red
        Color(red: 0.2, green: 0.8, blue: 0.2),   // 2 Green
        Color(red: 0.8, green: 0.8, blue: 0.2),   // 3 Yellow
        Color(red: 0.2, green: 0.4, blue: 0.9),   // 4 Blue
        Color(red: 0.8, green: 0.2, blue: 0.8),   // 5 Magenta
        Color(red: 0.2, green: 0.8, blue: 0.8),   // 6 Cyan
        Color(red: 0.8, green: 0.8, blue: 0.8),   // 7 White
    ]

    private static let brightColors: [Color] = [
        Color(red: 0.5, green: 0.5, blue: 0.5),   // 8  Bright Black (Gray)
        Color(red: 1.0, green: 0.3, blue: 0.3),   // 9  Bright Red
        Color(red: 0.3, green: 1.0, blue: 0.3),   // 10 Bright Green
        Color(red: 1.0, green: 1.0, blue: 0.3),   // 11 Bright Yellow
        Color(red: 0.4, green: 0.6, blue: 1.0),   // 12 Bright Blue
        Color(red: 1.0, green: 0.3, blue: 1.0),   // 13 Bright Magenta
        Color(red: 0.3, green: 1.0, blue: 1.0),   // 14 Bright Cyan
        Color(red: 1.0, green: 1.0, blue: 1.0),   // 15 Bright White
    ]

    static func paletteColor(_ index: UInt8) -> Color {
        if index < 8 { return standardColors[Int(index)] }
        if index < 16 { return brightColors[Int(index - 8)] }
        if index < 232 {
            // 6x6x6 color cube (indices 16-231)
            let adjusted = Int(index) - 16
            let r = adjusted / 36
            let g = (adjusted % 36) / 6
            let b = adjusted % 6
            return Color(
                red: r == 0 ? 0 : Double(r * 40 + 55) / 255,
                green: g == 0 ? 0 : Double(g * 40 + 55) / 255,
                blue: b == 0 ? 0 : Double(b * 40 + 55) / 255
            )
        }
        // Grayscale (indices 232-255)
        let gray = Double(Int(index) - 232) * 10 + 8
        return Color(red: gray / 255, green: gray / 255, blue: gray / 255)
    }
}

/// Terminal screen buffer with scrollback
@MainActor
public final class TerminalBuffer: ObservableObject {
    @Published public var lines: [[TerminalCell]]
    @Published public var cursorRow: Int = 0
    @Published public var cursorCol: Int = 0
    @Published public var cursorVisible: Bool = true
    @Published public var title: String = "Terminal"

    public private(set) var columns: Int
    public private(set) var rows: Int
    private let maxScrollback: Int

    // Current text attributes
    private var currentForeground: TerminalColor = .default
    private var currentBackground: TerminalColor = .default
    private var currentBold = false
    private var currentDim = false
    private var currentItalic = false
    private var currentUnderline = false
    private var currentBlink = false
    private var currentInverse = false
    private var currentStrikethrough = false

    // Scroll region
    private var scrollTop: Int = 0
    private var scrollBottom: Int

    // Saved cursor position
    private var savedCursorRow: Int = 0
    private var savedCursorCol: Int = 0

    // Alternate screen buffer
    private var mainBuffer: [[TerminalCell]]?
    private var isAlternateScreen = false

    // Scrollback
    public var scrollbackLines: [[TerminalCell]] = []

    private let parser = ANSIParser()

    public init(columns: Int = 80, rows: Int = 24, maxScrollback: Int = 10000) {
        self.columns = columns
        self.rows = rows
        self.maxScrollback = maxScrollback
        self.scrollBottom = rows - 1

        let emptyLine = Array(repeating: TerminalCell.empty, count: columns)
        self.lines = Array(repeating: emptyLine, count: rows)
    }

    // MARK: - Input Processing

    /// Process terminal output data (from VM stdout)
    public func processOutput(_ data: Data) {
        let tokens = parser.parse(data)
        for token in tokens {
            processToken(token)
        }
    }

    public func processOutput(_ string: String) {
        let tokens = parser.parse(string)
        for token in tokens {
            processToken(token)
        }
    }

    private func processToken(_ token: ANSIParser.Token) {
        switch token {
        case .text(let text):
            for char in text {
                putCharacter(char)
            }

        case .sgr(let cmd):
            applySGR(cmd)

        case .cursorMove(let move):
            applyCursorMove(move)

        case .cursorPosition(let row, let col):
            cursorRow = min(max(row - 1, 0), rows - 1)
            cursorCol = min(max(col - 1, 0), columns - 1)

        case .eraseDisplay(let mode):
            eraseDisplay(mode)

        case .eraseLine(let mode):
            eraseLine(mode)

        case .newline:
            lineFeed()

        case .carriageReturn:
            cursorCol = 0

        case .backspace:
            if cursorCol > 0 { cursorCol -= 1 }

        case .tab:
            cursorCol = min(((cursorCol / 8) + 1) * 8, columns - 1)

        case .bell:
            // Could trigger haptic feedback
            break

        case .saveCursor:
            savedCursorRow = cursorRow
            savedCursorCol = cursorCol

        case .restoreCursor:
            cursorRow = savedCursorRow
            cursorCol = savedCursorCol

        case .showCursor:
            cursorVisible = true

        case .hideCursor:
            cursorVisible = false

        case .alternateScreen(let enable):
            if enable && !isAlternateScreen {
                mainBuffer = lines
                let emptyLine = Array(repeating: TerminalCell.empty, count: columns)
                lines = Array(repeating: emptyLine, count: rows)
                isAlternateScreen = true
            } else if !enable && isAlternateScreen {
                if let saved = mainBuffer {
                    lines = saved
                }
                mainBuffer = nil
                isAlternateScreen = false
            }

        case .setScrollRegion(let top, let bottom):
            scrollTop = max(top - 1, 0)
            scrollBottom = min(bottom - 1, rows - 1)

        case .scrollUp(let n):
            for _ in 0..<n { scrollUp() }

        case .scrollDown(let n):
            for _ in 0..<n { scrollDown() }

        case .insertLines(let n):
            for _ in 0..<n {
                let emptyLine = Array(repeating: currentCell(" "), count: columns)
                if cursorRow <= scrollBottom {
                    lines.remove(at: scrollBottom)
                    lines.insert(emptyLine, at: cursorRow)
                }
            }

        case .deleteLines(let n):
            for _ in 0..<n {
                let emptyLine = Array(repeating: currentCell(" "), count: columns)
                if cursorRow <= scrollBottom {
                    lines.remove(at: cursorRow)
                    lines.insert(emptyLine, at: scrollBottom)
                }
            }

        case .insertCharacters(let n):
            for _ in 0..<n {
                if cursorCol < columns {
                    lines[cursorRow].insert(currentCell(" "), at: cursorCol)
                    lines[cursorRow].removeLast()
                }
            }

        case .deleteCharacters(let n):
            for _ in 0..<n {
                if cursorCol < columns {
                    lines[cursorRow].remove(at: cursorCol)
                    lines[cursorRow].append(currentCell(" "))
                }
            }

        case .setTitle(let newTitle):
            title = newTitle

        case .reportCursorPosition:
            // Should send back ESC[row;colR but we handle this at the VM process level
            break
        }
    }

    // MARK: - Character Writing

    private func putCharacter(_ char: Character) {
        if cursorCol >= columns {
            cursorCol = 0
            lineFeed()
        }

        lines[cursorRow][cursorCol] = currentCell(char)
        cursorCol += 1
    }

    private func currentCell(_ char: Character) -> TerminalCell {
        TerminalCell(
            character: char,
            foreground: currentForeground,
            background: currentBackground,
            bold: currentBold,
            dim: currentDim,
            italic: currentItalic,
            underline: currentUnderline,
            blink: currentBlink,
            inverse: currentInverse,
            strikethrough: currentStrikethrough
        )
    }

    // MARK: - Line Operations

    private func lineFeed() {
        if cursorRow == scrollBottom {
            scrollUp()
        } else if cursorRow < rows - 1 {
            cursorRow += 1
        }
    }

    private func scrollUp() {
        // Save the top line to scrollback (unless alternate screen)
        if !isAlternateScreen && scrollTop == 0 {
            scrollbackLines.append(lines[scrollTop])
            if scrollbackLines.count > maxScrollback {
                scrollbackLines.removeFirst()
            }
        }

        let emptyLine = Array(repeating: TerminalCell.empty, count: columns)
        lines.remove(at: scrollTop)
        lines.insert(emptyLine, at: scrollBottom)
    }

    private func scrollDown() {
        let emptyLine = Array(repeating: TerminalCell.empty, count: columns)
        lines.remove(at: scrollBottom)
        lines.insert(emptyLine, at: scrollTop)
    }

    // MARK: - SGR Application

    private func applySGR(_ cmd: ANSIParser.SGRCommand) {
        switch cmd {
        case .reset:
            currentForeground = .default
            currentBackground = .default
            currentBold = false
            currentDim = false
            currentItalic = false
            currentUnderline = false
            currentBlink = false
            currentInverse = false
            currentStrikethrough = false
        case .bold: currentBold = true
        case .dim: currentDim = true
        case .italic: currentItalic = true
        case .underline: currentUnderline = true
        case .blink: currentBlink = true
        case .inverse: currentInverse = true
        case .hidden: break
        case .strikethrough: currentStrikethrough = true
        case .boldOff: currentBold = false; currentDim = false
        case .italicOff: currentItalic = false
        case .underlineOff: currentUnderline = false
        case .blinkOff: currentBlink = false
        case .inverseOff: currentInverse = false
        case .hiddenOff: break
        case .strikethroughOff: currentStrikethrough = false
        case .foreground(let color): currentForeground = mapColor(color)
        case .background(let color): currentBackground = mapColor(color)
        case .defaultForeground: currentForeground = .default
        case .defaultBackground: currentBackground = .default
        }
    }

    private func mapColor(_ ansiColor: ANSIParser.ANSIColor) -> TerminalColor {
        switch ansiColor {
        case .standard(let n): return .standard(n)
        case .bright(let n): return .bright(n)
        case .palette(let n): return .palette(n)
        case .rgb(let r, let g, let b): return .rgb(r, g, b)
        }
    }

    // MARK: - Cursor Movement

    private func applyCursorMove(_ move: ANSIParser.CursorMove) {
        switch move {
        case .up(let n): cursorRow = max(cursorRow - n, 0)
        case .down(let n): cursorRow = min(cursorRow + n, rows - 1)
        case .forward(let n): cursorCol = min(cursorCol + n, columns - 1)
        case .backward(let n): cursorCol = max(cursorCol - n, 0)
        case .column(let col): cursorCol = min(max(col - 1, 0), columns - 1)
        case .nextLine(let n):
            cursorRow = min(cursorRow + n, rows - 1)
            cursorCol = 0
        case .previousLine(let n):
            cursorRow = max(cursorRow - n, 0)
            cursorCol = 0
        }
    }

    // MARK: - Erase Operations

    private func eraseDisplay(_ mode: ANSIParser.EraseMode) {
        let emptyLine = Array(repeating: TerminalCell.empty, count: columns)

        switch mode {
        case .toEnd:
            // Erase from cursor to end
            for col in cursorCol..<columns {
                lines[cursorRow][col] = .empty
            }
            for row in (cursorRow + 1)..<rows {
                lines[row] = emptyLine
            }
        case .toBeginning:
            for row in 0..<cursorRow {
                lines[row] = emptyLine
            }
            for col in 0...cursorCol {
                lines[cursorRow][col] = .empty
            }
        case .all, .savedLines:
            lines = Array(repeating: emptyLine, count: rows)
        }
    }

    private func eraseLine(_ mode: ANSIParser.EraseMode) {
        switch mode {
        case .toEnd:
            for col in cursorCol..<columns {
                lines[cursorRow][col] = .empty
            }
        case .toBeginning:
            for col in 0...min(cursorCol, columns - 1) {
                lines[cursorRow][col] = .empty
            }
        case .all, .savedLines:
            lines[cursorRow] = Array(repeating: TerminalCell.empty, count: columns)
        }
    }

    // MARK: - Resize

    public func resize(columns newColumns: Int, rows newRows: Int) {
        let emptyLine = Array(repeating: TerminalCell.empty, count: newColumns)

        var newLines = Array(repeating: emptyLine, count: newRows)
        for row in 0..<min(self.rows, newRows) {
            var newLine = Array(repeating: TerminalCell.empty, count: newColumns)
            for col in 0..<min(self.columns, newColumns) {
                newLine[col] = lines[row][col]
            }
            newLines[row] = newLine
        }
        lines = newLines
        self.columns = newColumns
        self.rows = newRows
        cursorRow = min(cursorRow, newRows - 1)
        cursorCol = min(cursorCol, newColumns - 1)
        scrollTop = min(scrollTop, newRows - 1)
        scrollBottom = newRows - 1
    }

    // MARK: - Text Extraction

    /// Get all visible text as a plain string (for copy/paste)
    public func visibleText() -> String {
        lines.map { line in
            String(line.map(\.character)).trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }

    /// Get selected text range
    public func text(from startRow: Int, startCol: Int, to endRow: Int, endCol: Int) -> String {
        var result = ""
        for row in startRow...endRow {
            guard row >= 0 && row < rows else { continue }
            let start = row == startRow ? startCol : 0
            let end = row == endRow ? endCol : columns - 1
            for col in start...end {
                guard col >= 0 && col < columns else { continue }
                result.append(lines[row][col].character)
            }
            if row < endRow { result.append("\n") }
        }
        return result
    }
}
