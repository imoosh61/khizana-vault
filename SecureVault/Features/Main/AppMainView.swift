//
//  AppMainView.swift
//  SecureVault
//
//  نقطة الدخول: يقرر ما يُعرض (إعداد أول / قفل / المحتوى / خطأ) ويغطي الشاشة
//  عند الانتقال للخلفية كي لا تظهر البيانات في مبدّل التطبيقات.
//

import SwiftUI

struct AppMainView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var auth: BiometricAuthManager
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.dark.rawValue

    private var appearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .dark
    }

    var body: some View {
        ZStack {
            content

            if scenePhase != .active {
                PrivacyShieldView()
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .tint(Theme.accent)
        .preferredColorScheme(appearance.colorScheme)
        .animation(.easeInOut(duration: 0.15), value: scenePhase)
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background:
                auth.applicationDidEnterBackground()
            case .active:
                auth.applicationWillEnterForeground()
            default:
                break
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if environment.isReloading {
            LoadingStateView(title: "جارٍ تطبيق النسخة المستعادة…")
        } else if let persistence = environment.persistence {
            if !auth.isPasscodeConfigured {
                NavigationStack {
                    PasscodeSetupView(mode: .initial)
                }
            } else if auth.state == .unlocked {
                MainTabView()
                    .environment(\.managedObjectContext, persistence.viewContext)
                    .id(environment.generation)
            } else {
                LockScreenView()
            }
        } else {
            StartupErrorView(message: environment.startupError ?? "")
        }
    }
}

// MARK: - غطاء الخصوصية

struct PrivacyShieldView: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThickMaterial)
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 64))
                .foregroundStyle(Theme.accent)
        }
        .ignoresSafeArea()
    }
}

// MARK: - خطأ بدء التشغيل

private struct StartupErrorView: View {
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 52))
                .foregroundStyle(Theme.warning)
            Text("تعذّر تشغيل الخزنة")
                .font(.title2.bold())
            Text(verbatim: message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("لم يتم حذف أي بيانات. أعد تشغيل التطبيق، وإن استمر الخطأ فاستعد نسخة احتياطية بعد إعادة التثبيت.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .vaultBackground()
    }
}
