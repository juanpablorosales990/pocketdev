import SwiftUI
#if canImport(Shared)
import Shared
#endif
#if canImport(TerminalUI)
import TerminalUI
#endif
#if canImport(PocketDevFileManager)
import PocketDevFileManager
#endif

/// The main workspace view — split pane with terminal, file browser, and in-app browser
struct WorkspaceView: View {
    @EnvironmentObject var appState: AppState
    @State private var showFileBrowser = false
    @State private var showInAppBrowser = false
    @State private var splitRatio: CGFloat = 1.0
    @State private var browserURL = "http://localhost:3000"

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Top toolbar
                WorkspaceToolbar(
                    containerName: activeContainerName,
                    showFileBrowser: $showFileBrowser,
                    showInAppBrowser: $showInAppBrowser,
                    onStop: stopContainer,
                    onHome: { appState.currentScreen = .home }
                )

                // Main content area
                HStack(spacing: 0) {
                    // File browser (slide-over panel)
                    if showFileBrowser {
                        FileBrowserPanel()
                            .frame(width: min(geometry.size.width * 0.35, 300))
                            .transition(.move(edge: .leading))
                    }

                    // Terminal + optional browser split
                    VStack(spacing: 0) {
                        if showInAppBrowser {
                            // Split: terminal top, browser bottom
                            terminalPanel
                                .frame(height: geometry.size.height * splitRatio * 0.4)

                            Divider()
                                .gesture(
                                    DragGesture()
                                        .onChanged { value in
                                            let newRatio = value.location.y / geometry.size.height
                                            splitRatio = max(0.2, min(0.8, newRatio))
                                        }
                                )

                            InAppBrowserView(url: browserURL)
                        } else {
                            // Full terminal
                            terminalPanel
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var terminalPanel: some View {
        Group {
            if let containerID = appState.activeContainerID,
               let session = appState.terminalSessions[containerID] {
                TerminalView(buffer: session.buffer) { data in
                    session.sendInput(data)
                }
            } else {
                VStack {
                    Image(systemName: "terminal")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("No active container")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            }
        }
    }

    private var activeContainerName: String {
        guard let id = appState.activeContainerID else { return "No Container" }
        return appState.containers.first(where: { $0.id == id })?.name ?? "Container"
    }

    private func stopContainer() {
        guard let id = appState.activeContainerID else { return }
        Task {
            try? await appState.stopContainer(id)
        }
    }
}

// MARK: - Workspace Toolbar

struct WorkspaceToolbar: View {
    let containerName: String
    @Binding var showFileBrowser: Bool
    @Binding var showInAppBrowser: Bool
    let onStop: () -> Void
    let onHome: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onHome) {
                Image(systemName: "chevron.left")
            }

            Button(action: { withAnimation { showFileBrowser.toggle() } }) {
                Image(systemName: "sidebar.left")
                    .foregroundColor(showFileBrowser ? .green : .secondary)
            }

            Divider()
                .frame(height: 20)

            HStack(spacing: 6) {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                Text(containerName)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
            }

            Spacer()

            Button(action: { withAnimation { showInAppBrowser.toggle() } }) {
                Image(systemName: "globe")
                    .foregroundColor(showInAppBrowser ? .green : .secondary)
            }

            Menu {
                Button("New Terminal Tab", systemImage: "plus.rectangle") { }
                Button("Split Horizontally", systemImage: "rectangle.split.1x2") { }
                Button("Split Vertically", systemImage: "rectangle.split.2x1") { }
                Divider()
                Button("Container Info", systemImage: "info.circle") { }
                Button("Port Forwarding", systemImage: "network") { }
                Divider()
                Button("Stop Container", systemImage: "stop.fill", role: .destructive) {
                    onStop()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(PlatformColor.systemGray6)
    }
}

// MARK: - File Browser Panel

struct FileBrowserPanel: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = FileBrowserViewModel()

    var body: some View {
        FileBrowserView(viewModel: viewModel) { path in
            // Open file in editor or navigate in terminal
        }
        .onAppear {
            if let containerID = appState.activeContainerID,
               let session = appState.terminalSessions[containerID] {
                // Connect file browser to VM
                // viewModel.connect(spawnProcess: vm.spawnProcess)
            }
        }
    }
}

// MARK: - In-App Browser

struct InAppBrowserView: View {
    let url: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "globe")
                    .foregroundColor(.secondary)
                Text(url)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: {}) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(PlatformColor.systemGray5)

            // WebView would go here
            // WKWebView wrapped in UIViewRepresentable
            PlatformColor.systemGray6
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: "globe")
                            .font(.title)
                            .foregroundColor(.secondary)
                        Text("Preview: \(url)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
        }
    }
}
