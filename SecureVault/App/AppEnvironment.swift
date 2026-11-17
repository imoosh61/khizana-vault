//
//  AppEnvironment.swift
//  SecureVault
//
//  يمتلك كل الخدمات المشتركة (القفل، النسخ الاحتياطي، قاعدة البيانات)
//  ويتولّى إعادة تحميل قاعدة البيانات بعد الاستعادة دون إغلاق التطبيق.
//

import Foundation
import CoreData

@MainActor
final class AppEnvironment: ObservableObject {

    @Published private(set) var persistence: PersistenceController?
    @Published private(set) var startupError: String?
    @Published private(set) var isReloading = false
    /// يتغيّر عند كل إعادة تحميل لإجبار SwiftUI على بناء الواجهات من جديد.
    @Published private(set) var generation = 0

    let auth: BiometricAuthManager
    let backup: CloudBackupManager

    init() {
        auth = BiometricAuthManager()
        backup = CloudBackupManager()

        // يجب تطبيق أي استعادة معلّقة قبل فتح قاعدة البيانات.
        do {
            try VaultRestore.applyPendingRestoreIfNeeded()
        } catch {
            startupError = String(localized: "تعذّر تطبيق النسخة المستعادة: \(error.localizedDescription)")
        }
        loadPersistence()
    }

    private func loadPersistence() {
        do {
            persistence = try PersistenceController()
            // لا نمسح startupError الخاص بالاستعادة، فهو معلومة مفيدة للمستخدم.
        } catch {
            persistence = nil
            startupError = String(localized: "تعذّر فتح قاعدة البيانات: \(error.localizedDescription)")
        }
    }

    /// يُستدعى بعد نجاح `CloudBackupManager.restoreBackup`:
    /// يخفي الواجهات، يفصل القاعدة، يطبّق الاستعادة، ثم يعيد فتح القاعدة.
    func reloadAfterRestore() async {
        guard VaultRestore.hasPendingRestore else { return }

        isReloading = true

        // مهلة قصيرة كي تُزال الواجهات التي تحتفظ بكائنات Core Data قبل فصل المخزن.
        try? await Task.sleep(nanoseconds: 500_000_000)

        persistence?.tearDown()
        persistence = nil
        ThumbnailCache.shared.removeAll()

        var restoreError: String?
        do {
            try VaultRestore.applyPendingRestoreIfNeeded()
        } catch {
            restoreError = String(localized: "تعذّر تطبيق النسخة المستعادة: \(error.localizedDescription)")
        }

        loadPersistence()
        generation += 1
        isReloading = false

        if let restoreError {
            backup.reportFailure(restoreError)
        }
    }
}
