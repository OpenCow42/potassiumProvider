import PotassiumProviderCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: PotassiumProviderAppModel
    @State private var selectedTab: ProviderAppTab

    init(model: PotassiumProviderAppModel) {
        _model = ObservedObject(wrappedValue: model)
        _selectedTab = State(initialValue: ProviderAppTabSelectionPolicy.defaultSelection(
            configuredDomainCount: model.domains.count
        ))
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            ProviderStatusView(appModel: model) {
                selectedTab = .setup
            }
            .providerNavigationAnimation(animatesInitialAppearance: false)
            .tabItem {
                Label("Status", systemImage: "gauge.medium")
            }
            .tag(ProviderAppTab.status)

            ProviderSetupView(model: model)
                .providerNavigationAnimation()
                .tabItem {
                    Label("Setup", systemImage: "externaldrive.connected.to.line.below")
                }
                .tag(ProviderAppTab.setup)

            ConflictLogView(eventStore: model.providerEventStore)
                .providerNavigationAnimation()
                .tabItem {
                    Label("Activities", systemImage: "clock.arrow.circlepath")
                }
                .tag(ProviderAppTab.activities)
        }
        .onAppear {
            selectedTab = ProviderAppTabSelectionPolicy.defaultSelection(
                configuredDomainCount: model.domains.count
            )
        }
    }
}

enum ProviderAppTab: Hashable {
    case status
    case setup
    case activities
}

enum ProviderAppTabSelectionPolicy {
    static func defaultSelection(configuredDomainCount _: Int) -> ProviderAppTab {
        .status
    }
}

#Preview {
    ContentView(model: PotassiumProviderAppModel(
        accountStore: ProviderAccountFileStore(
            directoryURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("potassiumProviderPreviewAccounts", isDirectory: true)
        ),
        domainStore: DomainConfigurationFileStore(
            directoryURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("potassiumProviderPreview", isDirectory: true)
        ),
        tokenStore: InMemoryOAuthTokenStore()
    ))
}
