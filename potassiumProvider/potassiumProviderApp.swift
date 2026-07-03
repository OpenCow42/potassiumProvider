//
//  potassiumProviderApp.swift
//  potassiumProvider
//
//  Created by OpenCow on 03/07/2026.
//

import SwiftUI

@main
struct potassiumProviderApp: App {
    @StateObject private var model = PotassiumProviderAppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
