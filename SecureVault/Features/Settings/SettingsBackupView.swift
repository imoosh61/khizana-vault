//
//  SettingsBackupView.swift
//  SecureVault
//
//  الإعدادات: الأمان والقفل، المظهر واللغة، حساب Google Drive،
//  إنشاء نسخة مشفّرة مرفوعة، واستعادة النسخ السحابية بكلمة المرور.
//

import SwiftUI
import CoreData

struct SettingsBackupView: View {

    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var auth: BiometricAuthManager
    @EnvironmentObject private var backup: CloudBackupManager

    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.dark.rawValue

    @State private var showChangePasscode = false
    @State private var backupPassword = ""
    @State private var backupPasswordConfirm = ""
    @State private var restoreTarget: DriveFile?
    @State private var deleteTarget: DriveFile?

    private var passwordsValid: Bool {
        backupPassword.count >= 8 && backupPassword == backupPasswordConfirm
    }

    var body: some View {
        Form {
            securitySection
            appearanceSection
            ThemeSettingsSection()
            googleSection
            createBackupSection
            restoreSection
            aboutSection
            CrashReportSection()
        }
        .scrollContentBackground(.hidden)
        .vaultBackground()
        .navigationTitle("الإعدادات")
        .sheet(isPresented: $showChangePasscode) {
            NavigationStack {
                PasscodeSetupView(mode: .change) { showChangePasscode = false }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("إلغاء") { showChangePasscode = false }
                        }
                    }
            }
        }
        .sheet(item: $restoreTarget) { file in
            RestoreSheet(file: file) { password in
                restoreTarget = nil
                Task {
                    if await backup.restoreBackup(file, password: password) {
                        await environment.reloadAfterRestore()
                    }
                }
            }
        }
        .confirmationDialog(
            "حذف هذه النسخة من Google Drive نهائياً؟",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("حذف", role: .destructive) {
                if let file = deleteTarget {
                    Task { await backup.deleteBackup(file) }
                }
                deleteTarget = nil
            }
            Button("إلغاء", role: .cancel) { deleteTarget = nil }
        }
        .task {
            if backup.isSignedIn && backup.availableBackups.isEmpty {
                await backup.refreshBackupList()
            }
        }
    }

    // MARK: الأمان

    private var securitySection: some View {
        Section {
            Toggle(isOn: $auth.isBiometricsEnabled) {
                Label {
                    HStack {
                        Text("فتح بالبصمة")
                        if auth.biometryKind != .none {
                            Text(verbatim: "(\(auth.biometryKind.displayName))")
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: auth.biometryKind.systemImageName)
                        .foregroundStyle(Theme.accent)
                }
            }
            .disabled(auth.biometryKind == .none)

            Picker(selection: $auth.autoLockInterval) {
                Text("فوراً").tag(0.0)
                Text("30 ثانية").tag(30.0)
                Text("دقيقة واحدة").tag(60.0)
                Text("5 دقائق").tag(300.0)
            } label: {
                Label("القفل التلقائي", systemImage: "timer")
            }

            Button {
                showChangePasscode = true
            } label: {
                Label("تغيير رمز التطبيق", systemImage: "number.circle")
            }

            Button {
                auth.lock()
            } label: {
                Label("قفل الآن", systemImage: "lock.fill")
            }
        } header: {
            Text("الأمان")
        } footer: {
            if auth.biometryKind == .none {
                Text("المصادقة الحيوية غير متاحة أو غير مفعّلة على هذا الجهاز.")
            }
        }
        .listRowBackground(Theme.card)
    }

    // MARK: المظهر واللغة

    private var appearanceSection: some View {
        Section {
            Picker("المظهر", selection: $appearanceRaw) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)

            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                HStack {
                    Label("اللغة", systemImage: "globe")
                    Spacer()
                    Text(verbatim: currentLanguageName)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("المظهر واللغة")
        } footer: {
            Text("لتغيير لغة التطبيق افتح إعدادات النظام ← التطبيق ← اللغة.")
        }
        .listRowBackground(Theme.card)
    }

    private var currentLanguageName: String {
        let code = Bundle.main.preferredLocalizations.first ?? "ar"
        return Locale(identifier: code).localizedString(forLanguageCode: code)?.capitalized ?? code
    }

    // MARK: Google Drive

    private var googleSection: some View {
        Section {
            if !backup.isGoogleConfigured {
                Label {
                    Text("لم يتم ضبط Google Client ID. راجع ملف README لإكمال الإعداد.")
                        .font(.footnote)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                }
            }

            if backup.isSignedIn {
                HStack {
                    Label("متصل", systemImage: "checkmark.icloud.fill")
                        .foregroundStyle(Theme.secure)
                    Spacer()
                    Text(verbatim: backup.signedInEmail ?? "")
                        .font(Theme.mono(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Button(role: .destructive) {
                    backup.signOut()
                } label: {
                    Label("تسجيل الخروج", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } else {
                Button {
                    Task { await backup.signIn() }
                } label: {
                    Label("ربط حساب Google Drive", systemImage: "link.icloud")
                }
                .disabled(!backup.isGoogleConfigured)
            }
        } header: {
            Text("Google Drive")
        } footer: {
            Text("يصل التطبيق إلى مجلد مخفي خاص به فقط، ولا يرى بقية ملفاتك.")
        }
        .listRowBackground(Theme.card)
    }

    // MARK: إنشاء نسخة

    private var createBackupSection: some View {
        Section {
            SecureField("كلمة مرور التشفير (8 خانات على الأقل)", text: $backupPassword)
                .textContentType(.newPassword)
            SecureField("تأكيد كلمة المرور", text: $backupPasswordConfirm)
                .textContentType(.newPassword)

            if !backupPasswordConfirm.isEmpty && backupPassword != backupPasswordConfirm {
                Text("كلمتا المرور غير متطابقتين.")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button {
                Task {
                    let success = await backup.createBackup(password: backupPassword, context: context)
                    if success {
                        backupPassword = ""
                        backupPasswordConfirm = ""
                    }
                }
            } label: {
                HStack {
                    Spacer()
                    Label("إنشاء نسخة مشفّرة ورفعها", systemImage: "icloud.and.arrow.up.fill")
                        .bold()
                    Spacer()
                }
            }
            .disabled(!backup.isSignedIn || !passwordsValid || backup.phase.isBusy)

            statusRow
        } header: {
            HStack {
                Text("نسخة احتياطية مشفّرة")
                Spacer()
                SecureBadge(title: "AES-GCM-256")
            }
        } footer: {
            Text("تُشفَّر النسخة على جهازك قبل الرفع. إذا نسيت كلمة المرور فلا يمكن استرجاع النسخة أبداً.")
        }
        .listRowBackground(Theme.card)
    }

    @ViewBuilder
    private var statusRow: some View {
        switch backup.phase {
        case .idle:
            EmptyView()
        case .finished(let message):
            Label {
                Text(verbatim: message)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.secure)
            }
            .font(.footnote)
        case .failed(let message):
            Label {
                Text(verbatim: message)
            } icon: {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
            .font(.footnote)
        default:
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: backup.progress)
                Text(verbatim: backup.phase.localizedTitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: الاستعادة

    private var restoreSection: some View {
        Section {
            if !backup.isSignedIn {
                Text("اربط حساب Google Drive لعرض النسخ المتاحة.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if backup.isLoadingList && backup.availableBackups.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if backup.availableBackups.isEmpty {
                Text("لا توجد نسخ احتياطية في حسابك.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(backup.availableBackups) { file in
                    Button {
                        restoreTarget = file
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "lock.doc.fill")
                                .foregroundStyle(Theme.secure)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(verbatim: file.name)
                                    .font(Theme.mono(.footnote))
                                    .lineLimit(1)
                                    .foregroundStyle(.primary)
                                HStack(spacing: 8) {
                                    if let date = file.createdTime {
                                        Text(date, style: .date)
                                    }
                                    Text(verbatim: file.formattedSize)
                                        .font(Theme.mono(.caption2))
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.down.circle")
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .disabled(backup.phase.isBusy)
                    .swipeActions {
                        Button(role: .destructive) {
                            deleteTarget = file
                        } label: {
                            Label("حذف", systemImage: "trash")
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("استعادة من السحابة")
                Spacer()
                if backup.isSignedIn {
                    Button {
                        Task { await backup.refreshBackupList() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(backup.isLoadingList)
                }
            }
        }
        .listRowBackground(Theme.card)
    }

    // MARK: حول

    private var aboutSection: some View {
        Section {
            HStack {
                Text("الإصدار")
                Spacer()
                Text(verbatim: "\(AppInfo.version) (\(AppInfo.build))")
                    .font(Theme.mono(.footnote))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("التشفير")
                Spacer()
                Text(verbatim: "AES-GCM-256 • PBKDF2-SHA256")
                    .font(Theme.mono(.caption))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("حول")
        }
        .listRowBackground(Theme.card)
    }
}

// MARK: - نافذة الاستعادة

private struct RestoreSheet: View {

    let file: DriveFile
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "lock.doc.fill")
                            .foregroundStyle(Theme.secure)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: file.name)
                                .font(Theme.mono(.footnote))
                            Text(verbatim: file.formattedSize)
                                .font(Theme.mono(.caption2))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowBackground(Theme.card)

                Section {
                    SecureField("كلمة مرور التشفير", text: $password)
                        .textContentType(.password)
                } footer: {
                    Text("تحذير: ستُستبدل جميع الملاحظات والوسائط الحالية بمحتوى هذه النسخة.")
                        .foregroundStyle(Theme.warning)
                }
                .listRowBackground(Theme.card)

                Section {
                    Button {
                        dismiss()
                        onConfirm(password)
                    } label: {
                        HStack {
                            Spacer()
                            Label("استعادة", systemImage: "arrow.down.circle.fill").bold()
                            Spacer()
                        }
                    }
                    .disabled(password.isEmpty)
                }
                .listRowBackground(Theme.card)
            }
            .scrollContentBackground(.hidden)
            .vaultBackground()
            .navigationTitle("استعادة نسخة")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء") { dismiss() }
                }
            }
        }
    }
}
