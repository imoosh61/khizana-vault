//
//  CrashReporter.swift
//  SecureVault
//
//  يلتقط الاستثناءات والإشارات القاتلة ويحفظ تقريراً نصياً محلياً (لا يُرسل لأي جهة)
//  ليعرضه التطبيق في الإعدادات كي يمكن مشاركته يدوياً عند حدوث عطل.
//

import Foundation

enum CrashReporter {

    private static let fileName = "last-crash.txt"

    static var reportURL: URL {
        URL.applicationSupportDirectory.appending(path: fileName, directoryHint: .notDirectory)
    }

    static func install() {
        // نخزّن المسار مسبقاً: لا نحسبه داخل معالج الإشارات.
        reportPath = reportURL.path(percentEncoded: false)

        NSSetUncaughtExceptionHandler { exception in
            let text = """
            Exception: \(exception.name.rawValue)
            Reason: \(exception.reason ?? "-")
            Date: \(Date())
            Version: \(AppInfo.version) (\(AppInfo.build))

            \(exception.callStackSymbols.joined(separator: "\n"))
            """
            CrashReporter.write(text)
        }

        for sig in [SIGABRT, SIGILL, SIGSEGV, SIGBUS, SIGTRAP, SIGFPE] {
            signal(sig) { number in
                let text = """
                Signal: \(number)
                Date: \(Date())
                Version: \(AppInfo.version) (\(AppInfo.build))

                \(Thread.callStackSymbols.joined(separator: "\n"))
                """
                CrashReporter.write(text)
                signal(number, SIG_DFL)
                raise(number)
            }
        }
    }

    nonisolated(unsafe) private static var reportPath: String = ""

    private static func write(_ text: String) {
        guard !reportPath.isEmpty else { return }
        try? text.write(toFile: reportPath, atomically: true, encoding: .utf8)
    }

    static func lastReport() -> String? {
        try? String(contentsOf: reportURL, encoding: .utf8)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: reportURL)
    }
}
