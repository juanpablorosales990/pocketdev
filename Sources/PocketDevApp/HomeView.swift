import SwiftUI
#if canImport(Shared)
import Shared
#endif
#if canImport(PlatformAbstraction)
import PlatformAbstraction
#endif
#if canImport(ContainerRuntime)
import ContainerRuntime
#endif

struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingNewContainer = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Quick actions
                    HStack(spacing: 12) {
                        QuickActionButton(
                            icon: "plus.circle.fill",
                            label: "New Container",
                            color: .green
                        ) {
                            showingNewContainer = true
                        }

                        QuickActionButton(
                            icon: "arrow.down.circle.fill",
                            label: "Pull Image",
                            color: .blue
                        ) {
                            // TODO: Image pull sheet
                        }
                    }
                    .padding(.horizontal)

                    // Running containers
                    if !appState.containers.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Running Containers")
                                .font(.headline)
                                .padding(.horizontal)

                            ForEach(appState.containers) { container in
                                ContainerRow(container: container)
                                    .onTapGesture {
                                        appState.switchToContainer(container.id)
                                    }
                            }
                        }
                    }

                    // Templates section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Quick Start")
                            .font(.headline)
                            .padding(.horizontal)

                        LazyVGrid(columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible()),
                        ], spacing: 12) {
                            ForEach(ContainerTemplate.allCases.filter { $0 != .custom }) { template in
                                TemplateGridCard(template: template)
                            }
                        }
                        .padding(.horizontal)
                    }

                    // Device info
                    if let caps = appState.capabilities {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Device")
                                .font(.headline)
                                .padding(.horizontal)

                            HStack {
                                Label(caps.summary, systemImage: "cpu")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal)
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("PocketDev")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button(action: { appState.currentScreen = .settings }) {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
        .sheet(isPresented: $showingNewContainer) {
            NewContainerSheet()
        }
        #if os(iOS)
        .navigationViewStyle(.stack)
        #endif
    }
}

// MARK: - Quick Action Button

struct QuickActionButton: View {
    let icon: String
    let label: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(color)
                Text(label)
                    .font(.caption)
                    .foregroundColor(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(PlatformColor.systemGray6)
            .cornerRadius(12)
        }
    }
}

// MARK: - Container Row

struct ContainerRow: View {
    let container: ContainerStatus

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(container.name)
                    .font(.headline)
                Text(container.imageName)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(container.state.rawValue.capitalized)
                    .font(.caption)
                    .foregroundColor(statusColor)
                Text("\(container.cpuCount) CPU, \(container.memoryMB)MB")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(PlatformColor.systemGray6)
        .cornerRadius(12)
        .padding(.horizontal)
    }

    private var statusColor: Color {
        switch container.state {
        case .running: return .green
        case .booting: return .yellow
        case .suspended: return .orange
        case .stopped, .failed: return .red
        default: return .gray
        }
    }
}

// MARK: - Template Grid Card

struct TemplateGridCard: View {
    let template: ContainerTemplate
    @EnvironmentObject var appState: AppState
    @State private var errorMessage: String?

    var body: some View {
        Button(action: {
            Task {
                do {
                    try await appState.initializeRuntime()
                    let config = ContainerConfig(
                        name: template.displayName,
                        imageName: template.rawValue,
                        cpuCount: appState.capabilities?.recommendedCPUs ?? 2,
                        memoryMB: template.defaultMemoryMB
                    )
                    try await appState.createContainer(config: config)
                } catch {
                    errorMessage = error.localizedDescription
                    print("Container creation error: \(error)")
                }
            }
        }) {
            VStack(spacing: 8) {
                Image(systemName: template.iconName)
                    .font(.title2)
                    .foregroundColor(.green)
                Text(template.displayName)
                    .font(.caption)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                if let error = errorMessage {
                    Text(error)
                        .font(.system(size: 8))
                        .foregroundColor(.red)
                        .lineLimit(3)
                } else {
                    Text("~\(template.estimatedSizeMB)MB")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(PlatformColor.systemGray6)
            .cornerRadius(12)
        }
    }
}

// MARK: - New Container Sheet

struct NewContainerSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    @State private var name = ""
    @State private var selectedTemplate: ContainerTemplate = .aiCoder
    @State private var customImage = ""
    @State private var cpuCount = 2
    @State private var memoryMB = 512
    @State private var isCreating = false
    @State private var error: String?

    var body: some View {
        NavigationView {
            Form {
                Section("Container Name") {
                    TextField("My Project", text: $name)
                }

                Section("Template") {
                    Picker("Template", selection: $selectedTemplate) {
                        ForEach(ContainerTemplate.allCases) { template in
                            Text(template.displayName).tag(template)
                        }
                    }
                    .pickerStyle(.menu)

                    if selectedTemplate == .custom {
                        TextField("Image (e.g. alpine:latest)", text: $customImage)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                    }
                }

                Section("Resources") {
                    Stepper("CPUs: \(cpuCount)", value: $cpuCount, in: 1...(appState.capabilities?.recommendedCPUs ?? 4))
                    Stepper("Memory: \(memoryMB)MB", value: $memoryMB, in: 256...2048, step: 256)
                }

                if let error = error {
                    Section {
                        Text(error)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("New Container")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        createContainer()
                    }
                    .disabled(isCreating || name.isEmpty)
                }
            }
            .overlay {
                if isCreating {
                    ProgressView("Creating container...")
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                }
            }
        }
    }

    private func createContainer() {
        isCreating = true
        error = nil

        Task {
            do {
                try await appState.initializeRuntime()
                let imageName = selectedTemplate == .custom ? customImage : selectedTemplate.rawValue
                let config = ContainerConfig(
                    name: name,
                    imageName: imageName,
                    cpuCount: cpuCount,
                    memoryMB: memoryMB
                )
                try await appState.createContainer(config: config)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isCreating = false
        }
    }
}
