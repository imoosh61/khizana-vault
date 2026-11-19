//
//  FileImportCenter.swift
//  SecureVault
//
//  محرك استيراد الصور والفيديو من تطبيق «الملفات» — مصمَّم لمئات/آلاف الملفات الكبيرة.
//
//  التصميم (مرحلتان، قابل للاستئناف):
//   1) النقل: يُنسخ كل ملف مختار (روابط أصلية بلا asCopy) واحداً تلو الآخر عبر NSFileCoordinator
//      إلى «صندوق وارد» داخل التطبيق (Documents/Import). منتقي الملفات يُغلق فوراً لأنه لا ينسخ شيئاً.
//   2) المعالجة: يُنقل كل ملف من صندوق الوارد إلى مجلد الخزنة (نقل لحظي بلا مساحة إضافية)،
//      وتُحسب البصمة والمصغّرة، ويُحفظ في Core Data على سياق خلفي بدفعات.
//  أي ملف لم يُعالج يبقى في صندوق الوارد، فلو انقطع الاستيراد (انهيار/إغلاق) يُستأنف من حيث توقف.
//  ويمكن أيضاً وضع الملفات في صندوق الوارد يدوياً من تطبيق «الملفات» (على الـ iPhone ← خِزانة ← Import).
//

import Foundation
import UIKit
import CoreData
import ImageIO
import AVFoundation
import UniformTypeIdentifiers

// MARK: - صندوق الوارد

enum ImportInbox {

    static let folderName = "Import"
    private static let separator = "__"

    static var directory: URL {
        URL.documentsDirectory.appending(path: folderName, directoryHint: .isDirectory)
    }

    static func prepare() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path(percentEncoded: false)) {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // حماية تسمح بالاستئناف بعد فتح الجهاز، دون أن تُكتب في نسخ iCloud الاحتياطية.
        try? fm.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path(percentEncoded: false)
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = directory
        try? mutable.setResourceValues(values)
    }

    /// كل الملفات المنتظرة (بما فيها داخل مجلدات فرعية وضعها المستخدم يدوياً).
    static func pendingFiles() -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                files.append(url)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    static func pendingCount() -> Int { pendingFiles().count }

    /// مسار فريد داخل صندوق الوارد يحفظ الاسم الأصلي (يمنع تصادم الأسماء المتشابهة مثل 0.MOV).
    static func uniqueDestination(for originalName: String) -> URL {
        let token = UUID().uuidString.prefix(8).lowercased()
        let safeName = originalName.replacingOccurrences(of: "/", with: "_")
        return directory.appending(path: "\(token)\(separator)\(safeName)", directoryHint: .notDirectory)
    }

    static func originalName(of url: URL) -> String {
        let name = url.lastPathComponent
        guard let range = name.range(of: separator) else { return name }
        let original = String(name[range.upperBound...])
        return original.isEmpty ? name : original
    }

    /// يحذف المجلدات الفرعية الفارغة بعد المعالجة.
    static func removeEmptySubfolders() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for item in items where (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if ImportInboxScan.isEmptyTree(item) { try? fm.removeItem(at: item) }
        }
    }

    static func removeAll() {
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            items.forEach { try? fm.removeItem(at: $0) }
        }
    }
}

private enum ImportInboxScan {
    static func isEmptyTree(_ url: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey], options: []
        ) else { return true }
        for case let child as URL in enumerator {
            if (try? child.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { return false }
        }
        return true
    }
}

// MARK: - تقرير الأخطاء

/// يجمع أسباب الفشل بصياغة قصيرة موحّدة (بدل رسائل النظام الطويلة التي تحمل اسم كل ملف).
struct ImportReport: Sendable {
    var added = 0
    var failed = 0
    var ignored = 0
    var reasons: [String: (count: Int, example: String)] = [:]

    mutating func fail(_ reason: String, file: String) {
        failed += 1
        let current = reasons[reason]
        reasons[reason] = ((current?.count ?? 0) + 1, current?.example ?? file)
    }

    static func reason(for error: Error) -> String {
        if let mediaError = error as? MediaImportError {
            switch mediaError {
            case .copyFailed(let message): return String(localized: "تعذّر النسخ") + ": " + message.prefix(80)
            default: return mediaError.localizedDescription
            }
        }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError:
                return String(localized: "الملف لم يعد موجوداً في مكانه")
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return String(localized: "لا توجد صلاحية لقراءة الملف")
            case NSFileWriteOutOfSpaceError:
                return String(localized: "المساحة على الجهاز ممتلئة")
            case NSFileReadCorruptFileError:
                return String(localized: "الملف تالف")
            case NSUserCancelledError:
                return String(localized: "أُلغي تنزيل الملف من iCloud")
            default:
                break
            }
        }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) {
            return String(localized: "المساحة على الجهاز ممتلئة")
        }
        return "\(ns.domain) \(ns.code)"
    }

    func summary(stopped: Bool) -> String {
        var parts: [String] = []
        if added > 0 { parts.append(String(format: String(localized: "تمت إضافة %lld"), added)) }
        if failed > 0 { parts.append(String(format: String(localized: "فشل استيراد %lld"), failed)) }
        if ignored > 0 { parts.append(String(format: String(localized: "تم تجاهل %lld ملف ليس صورة أو فيديو"), ignored)) }
        if parts.isEmpty { parts.append(String(localized: "لم تتم إضافة أي ملف")) }
        var lines = [parts.joined(separator: " • ")]
        if stopped { lines.append(String(localized: "تم الإيقاف — الملفات المتبقية محفوظة ويمكنك المتابعة لاحقاً.")) }
        for (reason, info) in reasons.sorted(by: { $0.value.count > $1.value.count }).prefix(4) {
            lines.append("• \(reason) (\(info.count)) — \(info.example)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - المحرك

@MainActor
final class FileImportCenter: ObservableObject {

    static let shared = FileImportCenter()

    enum Phase: Equatable {
        case idle
        case scanning
        case transferring
        case processing
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    @Published private(set) var currentName = ""
    @Published private(set) var pendingCount = 0
    @Published var resultMessage: String?

    var isBusy: Bool { phase != .idle }

    private var stopRequested = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var didCleanup = false

    private init() {}

    // MARK: واجهة الاستخدام

    func refreshPending() {
        guard !isBusy else { return }
        if !didCleanup {
            didCleanup = true
            Self.cleanupLegacyTemporaryFiles()
        }
        ImportInbox.prepare()
        pendingCount = ImportInbox.pendingCount()
    }

    func stop() {
        stopRequested = true
    }

    func discardPending() {
        guard !isBusy else { return }
        ImportInbox.removeAll()
        pendingCount = 0
    }

    /// يبدأ استيراد ملفات/مجلدات اختارها المستخدم (روابط أصلية من منتقي الملفات بوضع asCopy = false).
    func start(picked urls: [URL], container: NSPersistentContainer) {
        guard !isBusy, !urls.isEmpty else { return }
        run(container: container, picked: urls)
    }

    /// يعالج ما في صندوق الوارد (استئناف بعد انقطاع أو ملفات وُضعت يدوياً).
    func resume(container: NSPersistentContainer) {
        guard !isBusy else { return }
        run(container: container, picked: nil)
    }

    // MARK: التشغيل

    private func run(container: NSPersistentContainer, picked: [URL]?) {
        stopRequested = false
        ImportInbox.prepare()
        beginKeepAlive()
        phase = .scanning
        completed = 0
        total = 0
        currentName = ""

        Task {
            var report = ImportReport()
            if let picked {
                await transfer(picked, report: &report)
            }
            if !stopRequested {
                await process(container: container, report: &report)
            }

            ImportInbox.removeEmptySubfolders()
            let stopped = stopRequested
            phase = .idle
            currentName = ""
            pendingCount = ImportInbox.pendingCount()
            endKeepAlive()
            resultMessage = report.summary(stopped: stopped && pendingCount > 0)
        }
    }

    // MARK: المرحلة 1 — النقل إلى صندوق الوارد

    private struct SourceGroup: Sendable {
        let root: URL
        let isFolder: Bool
        var files: [URL]
    }

    private func transfer(_ urls: [URL], report: inout ImportReport) async {
        phase = .scanning

        // الفحص: توسيع المجلدات المختارة إلى ملفاتها.
        let scan = await Task.detached(priority: .userInitiated) { Self.scan(urls) }.value
        report.ignored += scan.ignored
        for failure in scan.failures { report.fail(failure.reason, file: failure.file) }

        let groups = scan.groups
        let fileCount = groups.reduce(0) { $0 + $1.files.count }
        guard fileCount > 0 else { return }

        // التحقق من المساحة قبل البدء (الملفات تُنقل لاحقاً للخزنة بلا نسخة ثانية).
        if let available = Self.availableCapacity(), scan.totalBytes > 0,
           scan.totalBytes + 200_000_000 > available {
            let needed = ByteCountFormatter.string(fromByteCount: scan.totalBytes, countStyle: .file)
            let free = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            report.fail(
                String(format: String(localized: "المساحة غير كافية: الملفات تحتاج %@ والمتاح %@"), needed, free),
                file: String(format: String(localized: "%lld ملف"), fileCount)
            )
            report.failed += fileCount - 1
            stopRequested = true
            return
        }

        phase = .transferring
        total = fileCount
        completed = 0

        for group in groups {
            if stopRequested { break }
            let scoped = group.root.startAccessingSecurityScopedResource()
            for file in group.files {
                if stopRequested { break }
                await waitForProtectedData()
                currentName = file.lastPathComponent

                let result = await Task.detached(priority: .userInitiated) {
                    Self.copyToInbox(file)
                }.value
                if let failure = result {
                    report.fail(failure, file: file.lastPathComponent)
                }
                completed += 1
            }
            if scoped { group.root.stopAccessingSecurityScopedResource() }
        }
    }

    private struct ScanResult: Sendable {
        var groups: [SourceGroup] = []
        var ignored = 0
        var totalBytes: Int64 = 0
        var failures: [(reason: String, file: String)] = []
    }

    nonisolated private static func scan(_ urls: [URL]) -> ScanResult {
        var result = ScanResult()
        let fm = FileManager.default

        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if !isFolder {
                result.groups.append(SourceGroup(root: url, isFolder: false, files: [url]))
                result.totalBytes += fileSize(url)
                continue
            }

            guard let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else {
                result.failures.append((String(localized: "تعذّر فتح المجلد"), url.lastPathComponent))
                continue
            }

            var files: [URL] = []
            for case let child as URL in enumerator {
                var candidate = child
                let name = child.lastPathComponent
                // ملفات iCloud غير المنزّلة تظهر كـ «.اسم.icloud» — نحولها لاسمها الحقيقي فيُنزّلها المنسّق.
                if name.hasPrefix("."), name.hasSuffix(".icloud") {
                    let real = String(name.dropFirst().dropLast(".icloud".count))
                    candidate = child.deletingLastPathComponent().appending(path: real, directoryHint: .notDirectory)
                } else if name.hasPrefix(".") {
                    continue
                } else if (try? child.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) != true {
                    continue
                }

                if isLikelyMedia(candidate) {
                    files.append(candidate)
                    result.totalBytes += fileSize(child)
                } else {
                    result.ignored += 1
                }
            }
            result.groups.append(SourceGroup(root: url, isFolder: true, files: files))
        }
        return result
    }

    nonisolated private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    nonisolated private static func isLikelyMedia(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .video)
    }

    nonisolated private static func availableCapacity() -> Int64? {
        let values = try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// نسخ منسّق (يُنزّل ملفات iCloud عند الحاجة). يُرجع سبب الفشل أو nil عند النجاح.
    nonisolated private static func copyToInbox(_ source: URL) -> String? {
        autoreleasepool {
            let destination = ImportInbox.uniqueDestination(for: source.lastPathComponent)
            var coordinationError: NSError?
            var copyError: Error?

            NSFileCoordinator(filePresenter: nil).coordinate(
                readingItemAt: source, options: [.withoutChanges], error: &coordinationError
            ) { readable in
                do {
                    try FileManager.default.copyItem(at: readable, to: destination)
                } catch {
                    copyError = error
                }
            }

            if let error = coordinationError ?? copyError {
                try? FileManager.default.removeItem(at: destination)
                return ImportReport.reason(for: error)
            }
            return nil
        }
    }

    // MARK: المرحلة 2 — من صندوق الوارد إلى الخزنة

    private func process(container: NSPersistentContainer, report: inout ImportReport) async {
        let files = await Task.detached(priority: .userInitiated) { ImportInbox.pendingFiles() }.value
        guard !files.isEmpty else { return }

        phase = .processing
        total = files.count
        completed = 0

        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        context.undoManager = nil

        var batch: [String] = []
        let batchSize = 20

        func commit(_ names: [String]) async -> Bool {
            guard !names.isEmpty else { return true }
            await waitForProtectedData()
            return await context.perform {
                do {
                    try context.save()
                    context.reset()
                    return true
                } catch {
                    context.rollback()
                    return false
                }
            }
        }

        func record(_ names: [String], saved: Bool, into report: inout ImportReport) {
            if saved {
                report.added += names.count
            } else {
                names.forEach(MediaFileStore.removeFile(named:))
                for name in names { report.fail(String(localized: "تعذّر الحفظ في قاعدة البيانات"), file: name) }
            }
        }

        for file in files {
            if stopRequested { break }
            await waitForProtectedData()
            let displayName = ImportInbox.originalName(of: file)
            currentName = displayName

            let outcome = await Task.detached(priority: .userInitiated) {
                await Self.processInboxFile(file, displayName: displayName)
            }.value

            switch outcome {
            case .success(let info):
                await context.perform { _ = MediaItem.insert(in: context, info: info) }
                batch.append(info.fileName)
                if batch.count >= batchSize {
                    let names = batch
                    batch.removeAll()
                    let saved = await commit(names)
                    record(names, saved: saved, into: &report)
                }
            case .failure(let reason):
                report.fail(reason, file: displayName)
            }
            completed += 1
        }

        let remaining = batch
        batch.removeAll()
        let saved = await commit(remaining)
        record(remaining, saved: saved, into: &report)
    }

    private enum FileOutcome: Sendable {
        case success(ImportedMediaInfo)
        case failure(String)
    }

    nonisolated private static func processInboxFile(_ file: URL, displayName: String) async -> FileOutcome {
        guard let detected = await detectKind(file) else {
            try? FileManager.default.removeItem(at: file)
            return .failure(String(localized: "ليس صورة أو فيديو صالحاً"))
        }
        do {
            let info = try await MediaFileStore.importFile(
                from: file,
                kind: detected.kind,
                originalName: displayName,
                preferredExtension: detected.preferredExtension,
                moveSource: true
            )
            return .success(info)
        } catch {
            // الملف الأصلي ما زال في «الملفات»، فلا نترك نسخة عالقة في صندوق الوارد.
            try? FileManager.default.removeItem(at: file)
            return .failure(ImportReport.reason(for: error))
        }
    }

    /// يحدد النوع بالامتداد، ثم بفحص المحتوى نفسه إن لم يكن الامتداد معروفاً.
    nonisolated private static func detectKind(_ url: URL) async -> (kind: MediaKind, preferredExtension: String?)? {
        let ext = url.pathExtension.lowercased()
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .movie) || type.conforms(to: .video) { return (.video, nil) }
            if type.conforms(to: .image) { return (.image, nil) }
        }

        let imageType: String? = autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  CGImageSourceGetCount(source) > 0,
                  let type = CGImageSourceGetType(source) else { return nil }
            return type as String
        }
        if let imageType {
            return (.image, UTType(imageType)?.preferredFilenameExtension)
        }

        let asset = AVURLAsset(url: url)
        if let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty {
            return (.video, "mov")
        }
        return nil
    }

    // MARK: إبقاء التطبيق يعمل

    /// الملفات وقاعدة البيانات محمية بالكامل؛ عند قفل الجهاز تصبح غير قابلة للقراءة.
    /// ننتظر بدل أن نفشل في كل الملفات المتبقية.
    private func waitForProtectedData() async {
        while !UIApplication.shared.isProtectedDataAvailable && !stopRequested {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func beginKeepAlive() {
        UIApplication.shared.isIdleTimerDisabled = true
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "vault-file-import") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
    }

    private func endKeepAlive() {
        UIApplication.shared.isIdleTimerDisabled = false
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: تنظيف بقايا الإصدارات السابقة

    /// النسخ القديمة (asCopy) تركت نسخاً في Documents/Inbox و tmp تستهلك المساحة.
    private static func cleanupLegacyTemporaryFiles() {
        let fm = FileManager.default
        try? fm.removeItem(at: URL.documentsDirectory.appending(path: "Inbox", directoryHint: .isDirectory))
        try? fm.removeItem(at: VaultStorage.rootDirectory.appending(path: "ImportStaging", directoryHint: .isDirectory))
        if let items = try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil) {
            for item in items {
                let name = item.lastPathComponent
                if name.hasSuffix("-Inbox") || name.hasPrefix("import-") {
                    try? fm.removeItem(at: item)
                }
            }
        }
    }
}
