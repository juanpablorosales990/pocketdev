import SwiftUI
#if canImport(Shared)
import Shared
#endif

#if canImport(UIKit)
import UIKit
#endif

/// The main terminal view — renders the terminal buffer with full ANSI color support,
/// cursor rendering, text selection, and keyboard input handling.
public struct TerminalView: View {
    @ObservedObject var buffer: TerminalBuffer
    let onInput: (Data) -> Void
    var onResize: ((Int, Int) -> Void)?

    @State private var fontSize: CGFloat = 13
    @State private var scrollOffset: CGFloat = 0
    @State private var isSelecting = false
    @State private var selectionStart: (row: Int, col: Int)?
    @State private var selectionEnd: (row: Int, col: Int)?
    @State private var lastCols: Int = 0
    @State private var lastRows: Int = 0
    @FocusState private var isFocused: Bool

    private let fontName = "Menlo"
    private let cellPadding: CGFloat = 0

    public init(buffer: TerminalBuffer, onInput: @escaping (Data) -> Void, onResize: ((Int, Int) -> Void)? = nil) {
        self.buffer = buffer
        self.onInput = onInput
        self.onResize = onResize
    }

    public var body: some View {
        GeometryReader { geometry in
            let cellWidth = charWidth(size: fontSize)
            let cellHeight = fontSize * 1.4
            let cols = max(20, Int(geometry.size.width / cellWidth))
            let rows = max(5, Int(geometry.size.height / cellHeight))

            ZStack(alignment: .topLeading) {
                // Background
                Color.black
                    .ignoresSafeArea()

                // Scrollback + visible buffer
                ScrollViewReader { scrollProxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            // Scrollback lines
                            ForEach(Array(buffer.scrollbackLines.enumerated()), id: \.offset) { index, line in
                                terminalLine(line, rowIndex: -(buffer.scrollbackLines.count - index), cellWidth: cellWidth, cellHeight: cellHeight, maxCols: cols)
                            }

                            // Visible buffer lines
                            ForEach(0..<buffer.rows, id: \.self) { row in
                                ZStack(alignment: .leading) {
                                    terminalLine(buffer.lines[row], rowIndex: row, cellWidth: cellWidth, cellHeight: cellHeight, maxCols: cols)

                                    // Cursor — white block like Terminal.app
                                    if buffer.cursorVisible && row == buffer.cursorRow {
                                        Rectangle()
                                            .fill(Color.white.opacity(0.85))
                                            .frame(width: cellWidth, height: cellHeight)
                                            .offset(x: CGFloat(buffer.cursorCol) * cellWidth)
                                            .blendMode(.screen)
                                    }
                                }
                                .id(row)
                            }
                        }
                    }
                    .onChange(of: buffer.cursorRow) { newRow in
                        withAnimation(.none) {
                            scrollProxy.scrollTo(newRow, anchor: .bottom)
                        }
                    }
                }

                #if canImport(UIKit)
                // Invisible text field for keyboard input (iOS only)
                TerminalInputView(onInput: onInput)
                    .focused($isFocused)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                #endif
            }
            .onTapGesture {
                isFocused = true
            }
            .gesture(
                DragGesture(minimumDistance: 5)
                    .onChanged { value in
                        handleSelectionDrag(value: value, cellWidth: cellWidth, cellHeight: cellHeight)
                    }
                    .onEnded { _ in
                        if let start = selectionStart, let end = selectionEnd {
                            let text = buffer.text(from: start.row, startCol: start.col, to: end.row, endCol: end.col)
                            #if canImport(UIKit)
                            UIPasteboard.general.string = text
                            #elseif canImport(AppKit)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                            #endif
                        }
                        isSelecting = false
                    }
            )
            .onAppear {
                isFocused = true
                resizeIfNeeded(cols: cols, rows: rows)
            }
            .onChange(of: geometry.size) { _ in
                resizeIfNeeded(cols: cols, rows: rows)
            }
        }
    }

    private func resizeIfNeeded(cols: Int, rows: Int) {
        if cols != lastCols || rows != lastRows {
            lastCols = cols
            lastRows = rows
            onResize?(cols, rows)
        }
    }

    // MARK: - Line Rendering

    private func terminalLine(_ cells: [TerminalCell], rowIndex: Int, cellWidth: CGFloat, cellHeight: CGFloat, maxCols: Int = 80) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<min(cells.count, maxCols), id: \.self) { col in
                let cell = cells[col]
                let isSelected = isCellSelected(row: rowIndex, col: col)

                Text(String(cell.character))
                    .font(.custom(fontName, size: fontSize))
                    .foregroundColor(isSelected ? .black : cellForegroundColor(cell))
                    .frame(width: cellWidth, height: cellHeight)
                    .background(isSelected ? Color.blue.opacity(0.5) : cellBackgroundColor(cell))
                    .bold(cell.bold)
                    .italic(cell.italic)
                    .underline(cell.underline)
                    .strikethrough(cell.strikethrough)
            }
        }
        .frame(height: cellHeight)
    }

    private func cellForegroundColor(_ cell: TerminalCell) -> Color {
        if cell.inverse {
            return cell.background == .default ? .black : cell.background.swiftUIColor
        }
        if cell.dim {
            return cell.foreground.swiftUIColor.opacity(0.6)
        }
        // White text on black background — like Terminal.app
        return cell.foreground == .default ? Color(white: 0.9) : cell.foreground.swiftUIColor
    }

    private func cellBackgroundColor(_ cell: TerminalCell) -> Color {
        if cell.inverse {
            return cell.foreground == .default ? Color(white: 0.9) : cell.foreground.swiftUIColor
        }
        return cell.background == .default ? .clear : cell.background.swiftUIColor
    }

    // MARK: - Text Selection

    private func isCellSelected(row: Int, col: Int) -> Bool {
        guard let start = selectionStart, let end = selectionEnd else { return false }
        let (startRow, startCol) = start.row <= end.row ? (start.row, start.col) : (end.row, end.col)
        let (endRow, endCol) = start.row <= end.row ? (end.row, end.col) : (start.row, start.col)

        if row < startRow || row > endRow { return false }
        if row == startRow && row == endRow { return col >= startCol && col <= endCol }
        if row == startRow { return col >= startCol }
        if row == endRow { return col <= endCol }
        return true
    }

    private func handleSelectionDrag(value: DragGesture.Value, cellWidth: CGFloat, cellHeight: CGFloat) {
        let col = max(0, min(Int(value.location.x / cellWidth), buffer.columns - 1))
        let row = max(0, min(Int(value.location.y / cellHeight), buffer.rows - 1))

        if !isSelecting {
            isSelecting = true
            let startCol = max(0, min(Int(value.startLocation.x / cellWidth), buffer.columns - 1))
            let startRow = max(0, min(Int(value.startLocation.y / cellHeight), buffer.rows - 1))
            selectionStart = (row: startRow, col: startCol)
        }
        selectionEnd = (row: row, col: col)
    }

    // MARK: - Helpers

    private func charWidth(size: CGFloat) -> CGFloat {
        #if canImport(UIKit)
        let font = UIFont(name: fontName, size: size) ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let charSize = ("W" as NSString).size(withAttributes: attrs)
        return charSize.width
        #elseif canImport(AppKit)
        let font = NSFont(name: fontName, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let charSize = ("W" as NSString).size(withAttributes: attrs)
        return charSize.width
        #else
        return size * 0.6
        #endif
    }
}

// MARK: - Keyboard Input Handler (iOS)

#if canImport(UIKit)

struct TerminalInputView: UIViewRepresentable {
    let onInput: (Data) -> Void

    func makeUIView(context: Context) -> TerminalInputUIView {
        let view = TerminalInputUIView()
        view.onInput = onInput
        return view
    }

    func updateUIView(_ uiView: TerminalInputUIView, context: Context) {}
}

class TerminalInputUIView: UIView, UIKeyInput {
    var onInput: ((Data) -> Void)?

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { false }

    // Enable paste
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc override func paste(_ sender: Any?) {
        if let text = UIPasteboard.general.string, let data = text.data(using: .utf8) {
            onInput?(data)
        }
    }

    // Support hardware keyboard
    override var keyCommands: [UIKeyCommand]? {
        var commands: [UIKeyCommand] = []

        // Ctrl+key combinations
        for char in "abcdefghijklmnopqrstuvwxyz" {
            commands.append(UIKeyCommand(
                input: String(char),
                modifierFlags: .control,
                action: #selector(handleCtrlKey(_:))
            ))
        }

        // Cmd+V for paste
        commands.append(UIKeyCommand(input: "v", modifierFlags: .command, action: #selector(handlePaste)))

        // Special keys
        commands.append(UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(handleArrowKey(_:))))
        commands.append(UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(handleArrowKey(_:))))
        commands.append(UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(handleArrowKey(_:))))
        commands.append(UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(handleArrowKey(_:))))
        commands.append(UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(handleEscape)))

        // Tab
        commands.append(UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(handleTab)))

        return commands
    }

    func insertText(_ text: String) {
        if let data = text.data(using: .utf8) {
            onInput?(data)
        }
    }

    func deleteBackward() {
        onInput?(Data([0x7F])) // DEL
    }

    @objc func handleCtrlKey(_ command: UIKeyCommand) {
        guard let input = command.input, let char = input.first else { return }
        let ctrlCode = UInt8(char.asciiValue! - UInt8(ascii: "a") + 1)
        onInput?(Data([ctrlCode]))
    }

    @objc func handleArrowKey(_ command: UIKeyCommand) {
        let sequence: Data
        switch command.input {
        case UIKeyCommand.inputUpArrow: sequence = Data([0x1B, 0x5B, 0x41]) // ESC[A
        case UIKeyCommand.inputDownArrow: sequence = Data([0x1B, 0x5B, 0x42]) // ESC[B
        case UIKeyCommand.inputRightArrow: sequence = Data([0x1B, 0x5B, 0x43]) // ESC[C
        case UIKeyCommand.inputLeftArrow: sequence = Data([0x1B, 0x5B, 0x44]) // ESC[D
        default: return
        }
        onInput?(sequence)
    }

    @objc func handleEscape() {
        onInput?(Data([0x1B]))
    }

    @objc func handleTab() {
        onInput?(Data([0x09]))
    }

    @objc func handlePaste() {
        if let text = UIPasteboard.general.string, let data = text.data(using: .utf8) {
            onInput?(data)
        }
    }

    // Handle Enter key
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if press.key?.keyCode == .keyboardReturnOrEnter {
                onInput?(Data([0x0D])) // CR
                return
            }
        }
        super.pressesBegan(presses, with: event)
    }
}

#endif

// MARK: - Terminal Session

/// Connects a TerminalBuffer to a VM process
@MainActor
public final class TerminalSession: ObservableObject {
    @Published public var buffer: TerminalBuffer
    public let id: String

    private var process: (any VMProcess)?
    private var outputTask: Task<Void, Never>?

    public init(id: String = UUID().uuidString, columns: Int = 80, rows: Int = 24) {
        self.id = id
        self.buffer = TerminalBuffer(columns: columns, rows: rows)
    }

    /// Attach to a VM process and start streaming I/O
    public func attach(to process: any VMProcess) {
        self.process = process

        outputTask = Task { [weak self] in
            for await event in process.output {
                guard let self = self else { break }
                switch event {
                case .stdout(let data):
                    await MainActor.run {
                        self.buffer.processOutput(data)
                    }
                case .stderr(let data):
                    await MainActor.run {
                        self.buffer.processOutput(data)
                    }
                case .exit(let code):
                    await MainActor.run {
                        self.buffer.processOutput("\r\n[Process exited with code \(code)]\r\n")
                    }
                }
            }
        }
    }

    /// Send keyboard input to the process
    public func sendInput(_ data: Data) {
        guard let process = process else { return }
        Task {
            try? await process.write(data)
        }
    }

    /// Resize the terminal
    public func resize(columns: Int, rows: Int) {
        buffer.resize(columns: columns, rows: rows)
        if let process = process {
            Task {
                try? await process.resize(TerminalSize(columns: UInt16(columns), rows: UInt16(rows)))
            }
        }
    }

    /// Detach from the process
    public func detach() {
        outputTask?.cancel()
        outputTask = nil
        process = nil
    }

    deinit {
        outputTask?.cancel()
    }
}

// MARK: - Preview

#if DEBUG

struct TerminalView_Previews: PreviewProvider {
    static var previews: some View {
        let buffer = TerminalBuffer(columns: 80, rows: 24)

        TerminalView(buffer: buffer) { _ in }
            .onAppear {
                buffer.processOutput("\u{1B}[1;32mroot@pocketdev\u{1B}[0m:\u{1B}[1;34m~\u{1B}[0m# ")
                buffer.processOutput("Welcome to PocketDev!\r\n")
                buffer.processOutput("Type 'help' for a list of commands.\r\n")
                buffer.processOutput("\u{1B}[1;32mroot@pocketdev\u{1B}[0m:\u{1B}[1;34m~\u{1B}[0m# ")
            }
            .preferredColorScheme(.dark)
    }
}
#endif
