//
//  SecureVaultApp.swift
//  SecureVault
//

import SwiftUI
import GoogleSignIn

@main
struct SecureVaultApp: App {

    @StateObject private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            AppMainView()
                .environmentObject(environment)
                .environmentObject(environment.auth)
                .environmentObject(environment.backup)
                .onOpenURL { url in
                    _ = GIDSignIn.sharedInstance.handle(url)
                }
                .task {
                    await environment.backup.restorePreviousSignIn()
                }
        }
    }
}
