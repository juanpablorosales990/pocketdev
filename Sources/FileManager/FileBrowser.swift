import SwiftUI
#if canImport(Shared)
import Shared
#endif

/// File tree node representing a file or directory in the container
public struct FileNode: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let size: Int64
    public let modifiedDate: Date
    public var children: [FileNode]?
    public var isExpanded: Bool = false

    public init(
        name: String,
        path: String,
        isDirectory: Bool,
        size: Int64 = 0,
        modifiedDate: Date = Date(),
        children: [FileNode]? = nil
    ) {
        self.id = path
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedDate = modifiedDate
        self.children = children
    }

    public var iconName: String {
        if isDirectory { return "folder.fill" }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "js", "jsx", "ts", "tsx": return "doc.text"
        case "py": return "doc.text"
        case "json": return "curlybraces"
        case "md": return "doc.richtext"
        case "yml", "yaml": return "doc.text"
        case "html": return "globe"
        case "css": return "paintbrush"
        case "sh", "bash", "zsh": return "terminal"
        case "png", "jpg", "jpeg", "gif", "svg": return "photo"
        case "git", "gitignore": return "arrow.triangle.branch"
        default: return "doc"
        }
    }

    public var iconColor: Color {
        if isDirectory { return .blue }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return .orange
        case "js", "jsx": return .yellow
        case "ts", "tsx": return .blue
        case "py": return .green
        case "json": return .purple
        case "md": return .gray
        case "html": return .red
        case "css": return .cyan
        default: return .secondary
        }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: FileNode, rhs: FileNode) -> Bool {
        lhs.id == rhs.id
    }
}

/// File browser view model — communicates with the VM to list/read/write files
@MainActor
public final class FileBrowserViewModel: ObservableObject {
    @Published public var rootNode: FileNode?
    @Published public var selectedFile: FileNode?
    @Published public var fileContent: String = ""
    @Published public var isLoading = false
    @Published public var error: String?

    private var vmProcess: ((ProcessSpec) async throws -> any VMProcess)?

    public init() {}

    /// Connect to a VM for file operations
    public func connect(spawnProcess: @escaping (ProcessSpec) async throws -> any VMProcess) {
        self.vmProcess = spawnProcess
    }

    /// List directory contents from the VM
    public func listDirectory(_ path: String = "/workspace") async {
        guard let spawn = vmProcess else { return }
        isLoading = true
        error = nil

        do {
            let safePath = path.replacingOccurrences(of: "'", with: "'\\''")
            let process = try await spawn(ProcessSpec(
                executablePath: "/bin/sh",
                arguments: ["-c", "find '\(safePath)' -maxdepth 2 -printf '%y %s %T@ %p\\n' 2>/dev/null | head -500"],
                workingDirectory: "/"
            ))

            var output = Data()
            for await event in process.output {
                if case .stdout(let data) = event {
                    output.append(data)
                }
            }

            let text = String(data: output, encoding: .utf8) ?? ""
            rootNode = parseFileTree(text, basePath: path)
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    /// Read a file's content from the VM
    public func readFile(_ path: String) async {
        guard let spawn = vmProcess else { return }
        isLoading = true

        do {
            let process = try await spawn(ProcessSpec(
                executablePath: "/bin/cat",
                arguments: [path],
                workingDirectory: "/"
            ))

            var output = Data()
            for await event in process.output {
                if case .stdout(let data) = event {
                    output.append(data)
                }
            }

            fileContent = String(data: output, encoding: .utf8) ?? ""
        } catch {
            self.error = "Failed to read file: \(error.localizedDescription)"
        }

        isLoading = false
    }

    /// Write content to a file in the VM
    public func writeFile(_ path: String, content: String) async throws {
        guard let spawn = vmProcess else { return }

        let safePath = path.replacingOccurrences(of: "'", with: "'\\''")
        let safeContent = content.replacingOccurrences(of: "'", with: "'\\''")
        let process = try await spawn(ProcessSpec(
            executablePath: "/bin/sh",
            arguments: ["-c", "printf '%s' '\(safeContent)' > '\(safePath)'"],
            workingDirectory: "/"
        ))
        _ = try await process.waitForExit()
    }

    /// Create a new directory
    public func createDirectory(_ path: String) async throws {
        guard let spawn = vmProcess else { return }
        let process = try await spawn(ProcessSpec(
            executablePath: "/bin/mkdir",
            arguments: ["-p", path],
            workingDirectory: "/"
        ))
        _ = try await process.waitForExit()
    }

    /// Delete a file or directory
    public func delete(_ path: String) async throws {
        guard let spawn = vmProcess else { return }
        let process = try await spawn(ProcessSpec(
            executablePath: "/bin/rm",
            arguments: ["-rf", path],
            workingDirectory: "/"
        ))
        _ = try await process.waitForExit()
    }

    // MARK: - Private

    private func parseFileTree(_ output: String, basePath: String) -> FileNode {
        var root = FileNode(name: basePath.split(separator: "/").last.map(String.init) ?? "workspace", path: basePath, isDirectory: true, children: [])

        var nodeMap: [String: FileNode] = [basePath: root]

        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3)
            guard parts.count >= 4 else { continue }

            let type = String(parts[0])
            let size = Int64(parts[1]) ?? 0
            let timestamp = Double(parts[2]) ?? 0
            let path = String(parts[3])

            guard path != basePath else { continue }

            let name = (path as NSString).lastPathComponent
            let parentPath = (path as NSString).deletingLastPathComponent
            let isDir = type == "d"

            let node = FileNode(
                name: name,
                path: path,
                isDirectory: isDir,
                size: size,
                modifiedDate: Date(timeIntervalSince1970: timestamp),
                children: isDir ? [] : nil
            )

            nodeMap[path] = node

            if var parent = nodeMap[parentPath] {
                parent.children = (parent.children ?? []) + [node]
                nodeMap[parentPath] = parent

                // Update root if needed
                if parentPath == basePath {
                    root.children = (root.children ?? []) + [node]
                }
            }
        }

        // Sort children: directories first, then alphabetically
        root.children?.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }

        return root
    }
}

// MARK: - File Browser View

public struct FileBrowserView: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    let onFileSelect: (String) -> Void

    public init(viewModel: FileBrowserViewModel, onFileSelect: @escaping (String) -> Void) {
        self.viewModel = viewModel
        self.onFileSelect = onFileSelect
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "folder.fill")
                    .foregroundColor(.blue)
                Text("Files")
                    .font(.headline)
                Spacer()
                Button(action: {
                    Task { await viewModel.listDirectory() }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(PlatformColor.systemGray6)

            Divider()

            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let root = viewModel.rootNode {
                List {
                    FileTreeView(node: root, depth: 0, onFileSelect: onFileSelect)
                }
                .listStyle(.plain)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("No files loaded")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - File Tree View

struct FileTreeView: View {
    let node: FileNode
    let depth: Int
    let onFileSelect: (String) -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                if node.isDirectory {
                    isExpanded.toggle()
                } else {
                    onFileSelect(node.path)
                }
            }) {
                HStack(spacing: 6) {
                    if node.isDirectory {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .frame(width: 12)
                    } else {
                        Spacer()
                            .frame(width: 12)
                    }

                    Image(systemName: node.iconName)
                        .foregroundColor(node.iconColor)
                        .frame(width: 16)

                    Text(node.name)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Spacer()

                    if !node.isDirectory && node.size > 0 {
                        Text(formatSize(node.size))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.leading, CGFloat(depth) * 16)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)

            if isExpanded, let children = node.children {
                ForEach(children.sorted { a, b in
                    if a.isDirectory != b.isDirectory { return a.isDirectory }
                    return a.name < b.name
                }) { child in
                    FileTreeView(node: child, depth: depth + 1, onFileSelect: onFileSelect)
                }
            }
        }
    }

    private func formatSize(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return "\(bytes / 1024 / 1024) MB"
    }
}
