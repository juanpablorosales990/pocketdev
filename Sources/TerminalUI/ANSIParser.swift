import Foundation

/// ANSI escape sequence parser for xterm-256color terminal emulation.
/// Handles SGR (Select Graphic Rendition), cursor movement, screen manipulation,
/// and all standard terminal escape sequences.
public final class ANSIParser {
    public enum Token {
        case text(String)
        case sgr(SGRCommand)
        case cursorMove(CursorMove)
        case eraseDisplay(EraseMode)
        case eraseLine(EraseMode)
        case scrollUp(Int)
        case scrollDown(Int)
        case setTitle(String)
        case bell
        case backspace
        case tab
        case newline
        case carriageReturn
        case saveCursor
        case restoreCursor
        case showCursor
        case hideCursor
        case alternateScreen(Bool)
        case setScrollRegion(top: Int, bottom: Int)
        case reportCursorPosition
        case insertLines(Int)
        case deleteLines(Int)
        case insertCharacters(Int)
        case deleteCharacters(Int)
        case cursorPosition(row: Int, col: Int)
    }

    public enum SGRCommand {
        case reset
        case bold
        case dim
        case italic
        case underline
        case blink
        case inverse
        case hidden
        case strikethrough
        case boldOff
        case italicOff
        case underlineOff
        case blinkOff
        case inverseOff
        case hiddenOff
        case strikethroughOff
        case foreground(ANSIColor)
        case background(ANSIColor)
        case defaultForeground
        case defaultBackground
    }

    public enum ANSIColor: Equatable {
        case standard(UInt8)     // 0-7
        case bright(UInt8)       // 8-15
        case palette(UInt8)      // 0-255
        case rgb(UInt8, UInt8, UInt8)
    }

    public enum CursorMove {
        case up(Int)
        case down(Int)
        case forward(Int)
        case backward(Int)
        case column(Int)
        case nextLine(Int)
        case previousLine(Int)
    }

    public enum EraseMode: Int {
        case toEnd = 0
        case toBeginning = 1
        case all = 2
        case savedLines = 3
    }

    private enum State {
        case normal
        case escape
        case csi
        case osc
        case oscString
    }

    private var state: State = .normal
    private var csiParams: String = ""
    private var oscString: String = ""

    public init() {}

    /// Parse a chunk of terminal output data into tokens
    public func parse(_ data: Data) -> [Token] {
        guard let string = String(data: data, encoding: .utf8) else {
            return [.text(String(data: data, encoding: .ascii) ?? "")]
        }
        return parse(string)
    }

    public func parse(_ string: String) -> [Token] {
        var tokens: [Token] = []
        var textBuffer = ""

        func flushText() {
            if !textBuffer.isEmpty {
                tokens.append(.text(textBuffer))
                textBuffer = ""
            }
        }

        for char in string {
            switch state {
            case .normal:
                switch char {
                case "\u{1B}": // ESC
                    flushText()
                    state = .escape
                case "\u{07}": // BEL
                    flushText()
                    tokens.append(.bell)
                case "\u{08}": // BS
                    flushText()
                    tokens.append(.backspace)
                case "\u{09}": // TAB
                    flushText()
                    tokens.append(.tab)
                case "\n": // LF
                    flushText()
                    tokens.append(.newline)
                case "\r": // CR
                    flushText()
                    tokens.append(.carriageReturn)
                default:
                    textBuffer.append(char)
                }

            case .escape:
                switch char {
                case "[": // CSI
                    state = .csi
                    csiParams = ""
                case "]": // OSC
                    state = .osc
                    oscString = ""
                case "7": // Save cursor
                    tokens.append(.saveCursor)
                    state = .normal
                case "8": // Restore cursor
                    tokens.append(.restoreCursor)
                    state = .normal
                case "c": // Full reset
                    tokens.append(.sgr(.reset))
                    state = .normal
                default:
                    // Unknown escape, output as text
                    textBuffer.append("\u{1B}")
                    textBuffer.append(char)
                    state = .normal
                }

            case .csi:
                if char.isNumber || char == ";" || char == "?" || char == ">" || char == "!" || char == " " {
                    csiParams.append(char)
                } else {
                    // End of CSI sequence
                    let params = parseCSIParams(csiParams)
                    tokens.append(contentsOf: handleCSI(finalChar: char, params: params, rawParams: csiParams))
                    state = .normal
                }

            case .osc:
                if char == "\u{07}" || char == "\u{1B}" {
                    // End of OSC (BEL or ESC\)
                    if let token = handleOSC(oscString) {
                        tokens.append(token)
                    }
                    state = char == "\u{1B}" ? .escape : .normal
                } else {
                    oscString.append(char)
                }

            case .oscString:
                if char == "\u{07}" {
                    state = .normal
                } else {
                    oscString.append(char)
                }
            }
        }

        flushText()
        return tokens
    }

    // MARK: - CSI Handling

    private func parseCSIParams(_ params: String) -> [Int] {
        let cleaned = params.replacingOccurrences(of: "?", with: "")
        return cleaned.split(separator: ";").compactMap { Int($0) }
    }

    private func handleCSI(finalChar: Character, params: [Int], rawParams: String) -> [Token] {
        let isPrivate = rawParams.hasPrefix("?")
        let p1 = params.first ?? 1
        let p2 = params.count > 1 ? params[1] : 1

        switch finalChar {
        case "A": return [.cursorMove(.up(max(1, p1)))]
        case "B": return [.cursorMove(.down(max(1, p1)))]
        case "C": return [.cursorMove(.forward(max(1, p1)))]
        case "D": return [.cursorMove(.backward(max(1, p1)))]
        case "E": return [.cursorMove(.nextLine(max(1, p1)))]
        case "F": return [.cursorMove(.previousLine(max(1, p1)))]
        case "G": return [.cursorMove(.column(max(1, p1)))]
        case "H", "f": return [.cursorPosition(row: max(1, p1), col: max(1, p2))]
        case "J": return [.eraseDisplay(EraseMode(rawValue: params.first ?? 0) ?? .toEnd)]
        case "K": return [.eraseLine(EraseMode(rawValue: params.first ?? 0) ?? .toEnd)]
        case "L": return [.insertLines(max(1, p1))]
        case "M": return [.deleteLines(max(1, p1))]
        case "@": return [.insertCharacters(max(1, p1))]
        case "P": return [.deleteCharacters(max(1, p1))]
        case "S": return [.scrollUp(max(1, p1))]
        case "T": return [.scrollDown(max(1, p1))]
        case "m": return handleSGR(params)
        case "r": return [.setScrollRegion(top: max(1, p1), bottom: max(1, p2))]
        case "s": return [.saveCursor]
        case "u": return [.restoreCursor]
        case "n":
            if p1 == 6 { return [.reportCursorPosition] }
            return []
        case "h":
            if isPrivate {
                switch params.first {
                case 25: return [.showCursor]
                case 1049: return [.alternateScreen(true)]
                case 2004: return [] // bracketed paste mode
                default: return []
                }
            }
            return []
        case "l":
            if isPrivate {
                switch params.first {
                case 25: return [.hideCursor]
                case 1049: return [.alternateScreen(false)]
                case 2004: return []
                default: return []
                }
            }
            return []
        default:
            return []
        }
    }

    private func handleSGR(_ params: [Int]) -> [Token] {
        if params.isEmpty {
            return [.sgr(.reset)]
        }

        var tokens: [Token] = []
        var i = 0
        while i < params.count {
            let p = params[i]
            switch p {
            case 0: tokens.append(.sgr(.reset))
            case 1: tokens.append(.sgr(.bold))
            case 2: tokens.append(.sgr(.dim))
            case 3: tokens.append(.sgr(.italic))
            case 4: tokens.append(.sgr(.underline))
            case 5: tokens.append(.sgr(.blink))
            case 7: tokens.append(.sgr(.inverse))
            case 8: tokens.append(.sgr(.hidden))
            case 9: tokens.append(.sgr(.strikethrough))
            case 22: tokens.append(.sgr(.boldOff))
            case 23: tokens.append(.sgr(.italicOff))
            case 24: tokens.append(.sgr(.underlineOff))
            case 25: tokens.append(.sgr(.blinkOff))
            case 27: tokens.append(.sgr(.inverseOff))
            case 28: tokens.append(.sgr(.hiddenOff))
            case 29: tokens.append(.sgr(.strikethroughOff))
            case 30...37: tokens.append(.sgr(.foreground(.standard(UInt8(p - 30)))))
            case 38: // Extended foreground
                if i + 1 < params.count {
                    if params[i + 1] == 5, i + 2 < params.count {
                        tokens.append(.sgr(.foreground(.palette(UInt8(params[i + 2])))))
                        i += 2 // skip subparams
                    } else if params[i + 1] == 2, i + 4 < params.count {
                        tokens.append(.sgr(.foreground(.rgb(UInt8(params[i + 2]), UInt8(params[i + 3]), UInt8(params[i + 4])))))
                        i += 4 // skip subparams
                    }
                }
            case 39: tokens.append(.sgr(.defaultForeground))
            case 40...47: tokens.append(.sgr(.background(.standard(UInt8(p - 40)))))
            case 48: // Extended background
                if i + 1 < params.count {
                    if params[i + 1] == 5, i + 2 < params.count {
                        tokens.append(.sgr(.background(.palette(UInt8(params[i + 2])))))
                        i += 2
                    } else if params[i + 1] == 2, i + 4 < params.count {
                        tokens.append(.sgr(.background(.rgb(UInt8(params[i + 2]), UInt8(params[i + 3]), UInt8(params[i + 4])))))
                        i += 4
                    }
                }
            case 49: tokens.append(.sgr(.defaultBackground))
            case 90...97: tokens.append(.sgr(.foreground(.bright(UInt8(p - 90)))))
            case 100...107: tokens.append(.sgr(.background(.bright(UInt8(p - 100)))))
            default: break
            }
            i += 1
        }
        return tokens
    }

    // MARK: - OSC Handling

    private func handleOSC(_ string: String) -> Token? {
        let parts = string.split(separator: ";", maxSplits: 1)
        guard let code = parts.first.flatMap({ Int($0) }) else { return nil }

        switch code {
        case 0, 2: // Set window title
            if parts.count > 1 {
                return .setTitle(String(parts[1]))
            }
        default:
            break
        }
        return nil
    }
}
