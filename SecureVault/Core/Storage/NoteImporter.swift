//
//  NoteImporter.swift
//  SecureVault
//
//  استيراد الملاحظات من ملفات نصية (txt / md / rtf / html) أو من الحافظة.
//  تطبيق "الملاحظات" في iOS لا يوفّر واجهة للتطبيقات الأخرى، لذا الطريق العملي
//  هو: مشاركة/نسخ الملاحظة من تطبيق الملاحظات ثم استيرادها هنا.
//

import Foundation
import CoreData
import UIKit
import UniformTypeIdentifiers

struct NoteImportSummary {
    var imported = 0
    var failed = 0
}

@MainActor
enum NoteImporter {

    static let contentTypes: [UTType] = {
        var types: [UTType] = [.plainText, .utf8PlainText, .text, .rtf, .html]
        for ext in ["md", "markdown", "txt"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }()

    private static let maxFileBytes = 5 * 1024 * 1024

    static func importFiles(_ urls: [URL], into context: NSManagedObjectContext) -> NoteImportSummary {
        var summary = NoteImportSummary()

        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            guard let text = readText(from: url), !text.trimmed.isEmpty else {
                summary.failed += 1
                continue
            }
            let title = url.deletingPathExtension().lastPathComponent
            Note.insert(in: context, title: title, body: text)
            summary.imported += 1
        }

        return commit(summary, in: context)
    }

    static func importFromClipboard(into context: NSManagedObjectContext) -> NoteImportSummary {
        var summary = NoteImportSummary()
        guard let text = UIPasteboard.general.string, !text.trimmed.isEmpty else {
            summary.failed = 1
            return summary
        }
        Note.insert(in: context, title: "", body: text)
        summary.imported = 1
        return commit(summary, in: context)
    }

    private static func commit(_ summary: NoteImportSummary, in context: NSManagedObjectContext) -> NoteImportSummary {
        guard summary.imported > 0 else { return summary }
        do {
            try context.saveIfNeeded()
            return summary
        } catch {
            context.rollback()
            return NoteImportSummary(imported: 0, failed: summary.imported + summary.failed)
        }
    }

    private static func readText(from url: URL) -> String? {
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > maxFileBytes {
            return nil
        }
        let ext = url.pathExtension.lowercased()

        switch ext {
        case "rtf", "html", "htm":
            guard let data = try? Data(contentsOf: url) else { return nil }
            let type: NSAttributedString.DocumentType = ext == "rtf" ? .rtf : .html
            let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: type, .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil
            )
            return attributed?.string
        default:
            for encoding in [String.Encoding.utf8, .utf16, .windowsCP1256, .isoLatin1] {
                if let text = try? String(contentsOf: url, encoding: encoding) { return text }
            }
            return nil
        }
    }
}
