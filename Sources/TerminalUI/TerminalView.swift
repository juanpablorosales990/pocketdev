import SwiftUI
import SwiftTerm
#if canImport(Shared)
import Shared
#endif

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - TerminalViewHolder (reference-type bridge)

/// Bridges the async TerminalSession world with the UIViewRepresentable world.
/// Holds a reference to SwiftTerm's TerminalView so the session can feed PTY data into it.
@MainActor
public final class TerminalViewHolder: ObservableObject {
    var terminalView: SwiftTerm.TerminalView?

    public init() {}

    func feed(data: Data) {
        let bytes = [UInt8](data)
        terminalView?.feed(byteArray: bytes[...])
    }

    func feed(text: String) {
        terminalView?.feed(text: text)
    }
}

// MARK: - SwiftTermView (platform UIViewRepresentable / NSViewRepresentable)

#if canImport(UIKit)

struct SwiftTermView: UIViewRepresentable {
    let holder: TerminalViewHolder
    let onSend: (Data) -> Void
    let onResize: (Int, Int) -> Void

    func makeCoordinator() -> SwiftTermCoordinator {
        SwiftTermCoordinator(onSend: onSend, onResize: onResize)
    }

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let font = UIFont(name: "Menlo", size: 13)
            ?? UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let tv = SwiftTerm.TerminalView(frame: .zero, font: font)
        tv.nativeBackgroundColor = .black
        tv.nativeForegroundColor = UIColor(white: 0.9, alpha: 1.0)
        tv.caretColor = .green
        tv.terminalDelegate = context.coordinator

        // Store reference so TerminalSession can feed data
        Task { @MainActor in
            holder.terminalView = tv
        }

        // Become first responder for keyboard input
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            _ = tv.becomeFirstResponder()
        }

        return tv
    }

    func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) {
        context.coordinator.onSend = onSend
        context.coordinator.onResize = onResize
    }
}

#elseif canImport(AppKit)

struct SwiftTermView: NSViewRepresentable {
    let holder: TerminalViewHolder
    let onSend: (Data) -> Void
    let onResize: (Int, Int) -> Void

    func makeCoordinator() -> SwiftTermCoordinator {
        SwiftTermCoordinator(onSend: onSend, onResize: onResize)
    }

    func makeNSView(context: Context) -> SwiftTerm.TerminalView {
        let tv = SwiftTerm.TerminalView(frame: .zero)
        tv.font = NSFont(name: "Menlo", size: 13)
            ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.nativeBackgroundColor = .black
        tv.nativeForegroundColor = NSColor(white: 0.9, alpha: 1.0)
        tv.caretColor = .green
        tv.terminalDelegate = context.coordinator

        Task { @MainActor in
            holder.terminalView = tv
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            tv.window?.makeFirstResponder(tv)
        }

        return tv
    }

    func updateNSView(_ nsView: SwiftTerm.TerminalView, context: Context) {
        context.coordinator.onSend = onSend
        context.coordinator.onResize = onResize
    }
}

#endif

// MARK: - SwiftTermCoordinator (TerminalViewDelegate)

final class SwiftTermCoordinator: TerminalViewDelegate {
    var onSend: (Data) -> Void
    var onResize: (Int, Int) -> Void

    init(onSend: @escaping (Data) -> Void, onResize: @escaping (Int, Int) -> Void) {
        self.onSend = onSend
        self.onResize = onResize
    }

    // User typed → forward to process
    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        onSend(Data(data))
    }

    // Terminal resized → forward new dimensions to process
    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        onResize(newCols, newRows)
    }

    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
    func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {}
    func bell(source: SwiftTerm.TerminalView) {}
    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {}
    func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
}

// MARK: - TerminalView (public SwiftUI wrapper)

public struct TerminalView: View {
    let buffer: TerminalViewHolder
    let onInput: (Data) -> Void
    var onResize: ((Int, Int) -> Void)?

    public init(buffer: TerminalViewHolder, onInput: @escaping (Data) -> Void, onResize: ((Int, Int) -> Void)? = nil) {
        self.buffer = buffer
        self.onInput = onInput
        self.onResize = onResize
    }

    public var body: some View {
        SwiftTermView(
            holder: buffer,
            onSend: onInput,
            onResize: { cols, rows in onResize?(cols, rows) }
        )
        .background(Color.black)
    }
}

// MARK: - Terminal Session

/// Connects a TerminalViewHolder to a VM process
@MainActor
public final class TerminalSession: ObservableObject {
    @Published public var buffer: TerminalViewHolder
    public let id: String

    private var process: (any VMProcess)?
    private var outputTask: Task<Void, Never>?

    public init(id: String = UUID().uuidString, columns: Int = 80, rows: Int = 24) {
        self.id = id
        self.buffer = TerminalViewHolder()
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
                        self.buffer.feed(data: data)
                    }
                case .stderr(let data):
                    await MainActor.run {
                        self.buffer.feed(data: data)
                    }
                case .exit(let code):
                    await MainActor.run {
                        self.buffer.feed(text: "\r\n[Process exited with code \(code)]\r\n")
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

    /// Resize the terminal (notify the process of new dimensions)
    public func resize(columns: Int, rows: Int) {
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
