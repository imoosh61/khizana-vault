//
//  SecurityGuard.swift
//  SecureVault
//
//  طبقة حماية وقت التشغيل: رصد تسجيل/بثّ الشاشة، مؤشرات الجيلبريك،
//  ومرفقات المصحِّح (Debugger). هذه الطبقة لا تحجب المستخدم أبداً؛ تُخفي
//  المحتوى أو تُحذّر فقط، لأن الأجهزة المجلبرَكة قد تكون مقصودة من المالك.
//

import UIKit
import Combine
import MachO

@MainActor
final class SecurityGuard: ObservableObject {

    /// الشاشة قيد التسجيل أو البث أو المرآة.
    @Published private(set) var isScreenCaptured: Bool = false
    /// رُصدت مؤشرات جيلبريك أو أدوات حقن.
    @Published private(set) var environmentSuspect: Bool = false
    /// يُرسل عند التقاط لقطة شاشة (لا يمكن منعها في iOS، لكن يمكن التنبيه).
    @Published private(set) var screenshotCount: Int = 0

    private var cancellables = Set<AnyCancellable>()

    init() {
        refreshCaptureState()
        environmentSuspect = SecurityGuard.detectSuspiciousEnvironment()

        NotificationCenter.default
            .publisher(for: UIScreen.capturedDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshCaptureState() }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: UIApplication.userDidTakeScreenshotNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.screenshotCount += 1 }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshCaptureState()
                self?.environmentSuspect = SecurityGuard.detectSuspiciousEnvironment()
            }
            .store(in: &cancellables)
    }

    private func refreshCaptureState() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        isScreenCaptured = scenes.contains { $0.screen.isCaptured }
    }

    /// يمسح الحافظة كي لا يبقى نص منسوخ من الخزنة متاحاً لتطبيقات أخرى.
    func clearClipboard() {
        let pasteboard = UIPasteboard.general
        if pasteboard.hasStrings || pasteboard.hasImages || pasteboard.hasURLs {
            pasteboard.items = []
        }
    }

    // MARK: - الرصد

    nonisolated static func detectSuspiciousEnvironment() -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return hasJailbreakFiles() || canWriteOutsideSandbox() || hasInjectionLibraries() || isDebuggerAttached()
        #endif
    }

    private nonisolated static func hasJailbreakFiles() -> Bool {
        let paths = [
            "/Applications/Cydia.app", "/Applications/Sileo.app", "/Applications/Zebra.app",
            "/Library/MobileSubstrate/MobileSubstrate.dylib", "/usr/libexec/cydia",
            "/usr/sbin/sshd", "/usr/bin/ssh", "/bin/bash", "/etc/apt",
            "/private/var/lib/apt/", "/var/jb", "/var/binpack", "/usr/lib/libhooker.dylib"
        ]
        return paths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    private nonisolated static func canWriteOutsideSandbox() -> Bool {
        let path = "/private/sv_probe_\(UUID().uuidString)"
        do {
            try "x".write(toFile: path, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(atPath: path)
            return true
        } catch {
            return false
        }
    }

    private nonisolated static func hasInjectionLibraries() -> Bool {
        let needles = ["substrate", "substitute", "libhooker", "frida", "cycript", "sslkillswitch"]
        for index in 0..<_dyld_image_count() {
            guard let cName = _dyld_get_image_name(index) else { continue }
            let name = String(cString: cName).lowercased()
            if needles.contains(where: { name.contains($0) }) { return true }
        }
        return false
    }

    private nonisolated static func isDebuggerAttached() -> Bool {
        #if DEBUG
        return false
        #else
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        return result == 0 && (info.kp_proc.p_flag & P_TRACED) != 0
        #endif
    }
}
