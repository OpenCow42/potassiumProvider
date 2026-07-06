import Darwin
import SwiftUI

struct potassiumProviderApp: App {
    @StateObject private var model = PotassiumProviderAppModel()
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        #if os(macOS)
        Window("potassiumProvider", id: MacAppPresenceConfiguration.mainWindowSceneID) {
            ContentView(model: model)
                .background(MacMainWindowIdentifierInstaller())
                .background(MacOpenWindowActionRegistrar())
        }
        #else
        WindowGroup {
            ContentView(model: model)
        }
        #endif
    }
}

@main
enum PotassiumProviderMain {
    static func main() {
        if FileProviderUninstallCommandLine.shouldHandle(arguments: CommandLine.arguments) {
            exit(FileProviderUninstallCommandLine.runInCurrentProcess(arguments: CommandLine.arguments))
        }

        potassiumProviderApp.main()
    }
}
