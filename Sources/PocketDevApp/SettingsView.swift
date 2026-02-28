import SwiftUI
import StoreKit
#if canImport(Shared)
import Shared
#endif
#if canImport(PlatformAbstraction)
import PlatformAbstraction
#endif

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var apiKey = ""
    @State private var fontSize: Double = 14
    @State private var showingSubscription = false

    var body: some View {
        NavigationView {
            Form {
                // Subscription
                Section("Subscription") {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(appState.currentTier.displayName)
                                .font(.headline)
                            if let price = appState.currentTier.monthlyPrice {
                                Text("$\(price)/month")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("Free")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        if appState.currentTier == .free {
                            Button("Upgrade") {
                                showingSubscription = true
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                        }
                    }
                }

                // Storage
                Section("Storage") {
                    HStack {
                        Text("Used")
                        Spacer()
                        Text("0 MB / \(appState.currentTier.maxStorageMB / 1024) GB")
                            .foregroundColor(.secondary)
                    }

                    Button("Clear Image Cache", role: .destructive) {
                        // TODO: Clear cache
                    }
                }

                // API Keys
                Section("API Keys") {
                    SecureField("Claude API Key (for AI Coder)", text: $apiKey)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()

                    Text("Your API key is stored locally and never sent to PocketDev servers.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Terminal
                Section("Terminal") {
                    HStack {
                        Text("Font Size")
                        Spacer()
                        Text("\(Int(fontSize))pt")
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $fontSize, in: 10...24, step: 1)
                }

                // Device Info
                Section("Device") {
                    if let caps = appState.capabilities {
                        InfoRow(label: "Backend", value: caps.localShellAvailable ? "Local Shell (PTY)" :
                                caps.bestPerformanceTier == .native ? "Hypervisor" :
                                caps.bestPerformanceTier == .emulated ? "QEMU TCG" : "Remote")
                        InfoRow(label: "CPU Cores", value: "\(caps.processorCount)")
                        InfoRow(label: "Memory", value: "\(caps.totalMemoryMB) MB")
                        InfoRow(label: "Apple Silicon", value: caps.isAppleSilicon ? "Yes" : "No")
                    }
                }

                // About
                Section("About") {
                    InfoRow(label: "Version", value: "1.0.0")
                    InfoRow(label: "Build", value: "1")

                    Link(destination: URL(string: "https://pocketdev.app")!) {
                        HStack {
                            Text("Website")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                        }
                    }

                    Link(destination: URL(string: "https://github.com/pocketdev/pocketdev")!) {
                        HStack {
                            Text("GitHub")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        appState.currentScreen = .home
                    }
                }
            }
        }
        .sheet(isPresented: $showingSubscription) {
            SubscriptionView()
        }
        #if os(iOS)
        .navigationViewStyle(.stack)
        #endif
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Subscription View

struct SubscriptionView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @State private var selectedTier: SubscriptionTier = .pro

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    Text("Unlock PocketDev")
                        .font(.title.bold())
                        .padding(.top, 20)

                    // Pro tier
                    SubscriptionCard(
                        tier: .pro,
                        isSelected: selectedTier == .pro,
                        features: [
                            "Unlimited containers",
                            "All pre-built images",
                            "10GB storage",
                            "GitHub integration",
                            "Push notifications",
                        ]
                    ) {
                        selectedTier = .pro
                    }

                    // Team tier
                    SubscriptionCard(
                        tier: .team,
                        isSelected: selectedTier == .team,
                        features: [
                            "Everything in Pro",
                            "Shared container sessions",
                            "Team image registry",
                            "Admin controls",
                            "SSO integration",
                        ]
                    ) {
                        selectedTier = .team
                    }

                    // Subscribe button
                    Button(action: {
                        // StoreKit purchase flow
                        Task {
                            await purchase(tier: selectedTier)
                        }
                    }) {
                        Text("Subscribe — \(selectedTier.monthlyPrice.map { "$\($0)/month" } ?? "Free")")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.green)
                            .foregroundColor(.black)
                            .cornerRadius(14)
                    }
                    .padding(.horizontal)

                    Text("Cancel anytime. Billed monthly.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button("Restore Purchases") {
                        Task { await restorePurchases() }
                    }
                    .font(.caption)
                }
                .padding(.bottom, 40)
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func purchase(tier: SubscriptionTier) async {
        guard let productID = tier.storeProductID else { return }

        do {
            let products = try await Product.products(for: [productID])
            guard let product = products.first else { return }

            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                switch verification {
                case .verified:
                    appState.currentTier = tier
                    dismiss()
                case .unverified:
                    break // Handle verification failure
                }
            case .pending, .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            // Handle purchase error
        }
    }

    private func restorePurchases() async {
        try? await AppStore.sync()
    }
}

struct SubscriptionCard: View {
    let tier: SubscriptionTier
    let isSelected: Bool
    let features: [String]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(tier.displayName)
                        .font(.title3.bold())
                    Spacer()
                    if let price = tier.monthlyPrice {
                        Text("$\(price)/mo")
                            .font(.headline)
                            .foregroundColor(.green)
                    }
                }

                ForEach(features, id: \.self) { feature in
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                        Text(feature)
                            .font(.body)
                    }
                }
            }
            .padding(16)
            .background(isSelected ? Color.green.opacity(0.1) : PlatformColor.systemGray6)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.green : Color.clear, lineWidth: 2)
            )
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
    }
}
