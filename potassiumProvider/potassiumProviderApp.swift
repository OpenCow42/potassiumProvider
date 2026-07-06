import Darwin
import SwiftUI

struct potassiumProviderApp: App {
    @StateObject private var model = PotassiumProviderAppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
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
