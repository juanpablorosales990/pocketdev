import SwiftUI
#if canImport(Shared)
import Shared
#endif
#if canImport(PlatformAbstraction)
import PlatformAbstraction
#endif

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        switch appState.currentScreen {
        case .onboarding:
            OnboardingView()
        case .home:
            HomeView()
        case .workspace:
            WorkspaceView()
        case .settings:
            SettingsView()
        }
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @State private var currentPage = 0
    @State private var isInitializing = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $currentPage) {
                // Page 1: Welcome
                VStack(spacing: 24) {
                    Spacer()

                    Image(systemName: "terminal.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(.linearGradient(
                            colors: [.green, .cyan],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))

                    Text("PocketDev")
                        .font(.system(size: 40, weight: .bold, design: .monospaced))

                    Text("Real Linux containers on your iPhone & iPad")
                        .font(.title3)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)

                    Spacer()

                    VStack(spacing: 8) {
                        FeatureRow(icon: "bolt.fill", color: .yellow, text: "Native ARM64 speed")
                        FeatureRow(icon: "shippingbox.fill", color: .blue, text: "Real Docker/OCI images")
                        FeatureRow(icon: "brain.head.profile", color: .purple, text: "Run Claude Code, Node.js, Python")
                        FeatureRow(icon: "wifi.slash", color: .green, text: "Works offline — runs on device")
                    }
                    .padding(.horizontal, 40)

                    Spacer()
                }
                .tag(0)

                // Page 2: Device capabilities
                VStack(spacing: 24) {
                    Spacer()

                    Image(systemName: "cpu")
                        .font(.system(size: 60))
                        .foregroundColor(.cyan)

                    Text("Your Device")
                        .font(.title.bold())

                    if let caps = appState.capabilities {
                        VStack(spacing: 12) {
                            CapabilityRow(
                                label: "Performance",
                                value: caps.bestPerformanceTier == .native ? "Native Speed" :
                                    caps.bestPerformanceTier == .emulated ? "Emulated (QEMU)" : "Cloud",
                                icon: caps.bestPerformanceTier == .native ? "bolt.fill" : "hare",
                                color: caps.bestPerformanceTier == .native ? .green : .yellow
                            )
                            CapabilityRow(
                                label: "CPU Cores",
                                value: "\(caps.processorCount) (\(caps.recommendedCPUs) for VM)",
                                icon: "cpu",
                                color: .blue
                            )
                            CapabilityRow(
                                label: "Memory",
                                value: "\(caps.totalMemoryMB)MB total, \(caps.recommendedMemoryMB)MB for VM",
                                icon: "memorychip",
                                color: .purple
                            )
                        }
                        .padding(.horizontal, 40)
                    }

                    Spacer()
                }
                .tag(1)

                // Page 3: Choose template
                VStack(spacing: 24) {
                    Text("Choose Your Environment")
                        .font(.title.bold())
                        .padding(.top, 40)

                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(ContainerTemplate.allCases.filter { $0 != .custom }) { template in
                                TemplateCard(template: template)
                            }
                        }
                        .padding(.horizontal, 20)
                    }

                    if isInitializing {
                        ProgressView("Setting up your environment...")
                            .padding()
                    }

                    if let error = error {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                            .padding(.horizontal)
                    }
                }
                .tag(2)
            }
            #if os(iOS)
            .tabViewStyle(.page(indexDisplayMode: .always))
            #endif

            // Bottom button
            if currentPage < 2 {
                Button(action: {
                    withAnimation { currentPage += 1 }
                }) {
                    Text("Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green)
                        .foregroundColor(.black)
                        .cornerRadius(14)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .background(PlatformColor.systemBackground)
    }
}

struct FeatureRow: View {
    let icon: String
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 24)
            Text(text)
                .font(.body)
            Spacer()
        }
    }
}

struct CapabilityRow: View {
    let label: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 24)
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(.body, design: .monospaced))
                .bold()
        }
        .padding(.vertical, 8)
    }
}

struct TemplateCard: View {
    let template: ContainerTemplate
    @EnvironmentObject var appState: AppState
    @State private var isCreating = false

    var body: some View {
        Button(action: {
            createFromTemplate()
        }) {
            HStack(spacing: 16) {
                Image(systemName: template.iconName)
                    .font(.title2)
                    .foregroundColor(.green)
                    .frame(width: 40, height: 40)
                    .background(Color.green.opacity(0.15))
                    .cornerRadius(10)

                VStack(alignment: .leading, spacing: 4) {
                    Text(template.displayName)
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text(template.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if isCreating {
                    ProgressView()
                } else {
                    VStack(alignment: .trailing) {
                        Text("~\(template.estimatedSizeMB)MB")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(16)
            .background(PlatformColor.systemGray6)
            .cornerRadius(12)
        }
        .disabled(isCreating)
    }

    private func createFromTemplate() {
        isCreating = true
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
                // Handle error
            }
            isCreating = false
        }
    }
}
