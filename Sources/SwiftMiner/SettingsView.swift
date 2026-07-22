import SwiftUI
import SwiftMinerCore
import SwiftMinerService
import TipKit
import AppKit
import UniformTypeIdentifiers

/// macOS Settings window using a Safari-style TabView with a top toolbar.
struct SettingsView: View {
    @Bindable private var settings = Settings.shared
    @Environment(NavigationModel.self) private var navigation
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView(settings: settings)
                .tabItem {
                    SettingsTabItem(tab: .general)
                }
                .tag(SettingsTab.general)

            AppearanceSettingsView(settings: settings)
                .tabItem {
                    SettingsTabItem(tab: .appearance)
                }
                .tag(SettingsTab.appearance)

            AccountSettingsView(navigation: navigation)
                .tabItem {
                    SettingsTabItem(tab: .accounts)
                }
                .tag(SettingsTab.accounts)

            MiningSettingsView(settings: settings)
                .tabItem {
                    SettingsTabItem(tab: .mining)
                }
                .tag(SettingsTab.mining)

            IntegrationsSettingsView(settings: settings)
                .tabItem {
                    SettingsTabItem(tab: .integrations)
                }
                .tag(SettingsTab.integrations)

            WebDashboardSettingsView(settings: settings)
                .tabItem {
                    SettingsTabItem(tab: .web)
                }
                .tag(SettingsTab.web)

            AdvancedSettingsView(settings: settings)
                .tabItem {
                    SettingsTabItem(tab: .advanced)
                }
                .tag(SettingsTab.advanced)

            UpdatesSettingsView()
                .tabItem {
                    SettingsTabItem(tab: .updates)
                }
                .tag(SettingsTab.updates)
        }
        .padding(.top, -2)
        .frame(width: 640)
        .onAppear(perform: consumePairingRequestIfNeeded)
        .onChange(of: navigation.pendingSwiftBotPairingRequest) { _, _ in
            consumePairingRequestIfNeeded()
        }
    }

    private func consumePairingRequestIfNeeded() {
        guard navigation.consumeSwiftBotPairingRequest() else { return }
        selectedTab = .integrations
    }
}

enum SettingsTab: String, CaseIterable, Hashable, Identifiable {
    case general
    case appearance
    case accounts
    case mining
    case integrations
    case web
    case advanced
    case updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .accounts: return "Accounts"
        case .mining: return "Mining"
        case .integrations: return "Integrations"
        case .web: return "Web"
        case .advanced: return "Advanced"
        case .updates: return "Updates"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .accounts: return "person.2"
        case .mining: return "cpu"
        case .integrations: return "app.connected.to.app.below.fill"
        case .web: return "globe"
        case .advanced: return "gearshape.2"
        case .updates: return "arrow.clockwise.circle"
        }
    }
}

/// Custom tab-item label with precise optical centering and tight spacing.
/// On macOS the system extracts the Image and Text from .tabItem to build the
/// segmented control; explicit sizing here ensures every icon sits consistently.
struct SettingsTabItem: View {
    let tab: SettingsTab

    var body: some View {
        VStack(spacing: 1) {
            Image(systemName: tab.systemImage)
                .font(.system(size: 12, weight: .medium))
                .imageScale(.small)
                .symbolRenderingMode(.hierarchical)
                .frame(height: 14, alignment: .center)
            Text(tab.title)
                .font(.system(size: 10, weight: .medium))
        }
    }
}

// MARK: - Shared Components

struct SettingsSecondaryText: View {
    let text: String
    var tint: Color = .secondary

    init(_ text: String, tint: Color = .secondary) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(tint)
            .padding(.vertical, 1)
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
        .environment(NavigationModel(clientId: "preview"))
}
