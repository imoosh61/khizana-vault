//
//  DocumentPickerPresenter.swift
//  SecureVault
//
//  يعرض منتقي الملفات مباشرة عبر UIKit من أعلى شاشة ظاهرة، بدون تغليفه في sheet من SwiftUI
//  (التغليف كان يسبب تعليق النافذة بعد الضغط على «فتح» مع الاختيارات الكبيرة).
//

import UIKit
import UniformTypeIdentifiers

@MainActor
enum DocumentPickerPresenter {

    private static var activeDelegate: PickerDelegate?

    /// - Parameter asCopy: false = روابط أصلية فورية بلا نسخ (للوسائط الكبيرة)، true = نسخ جاهزة (للملفات الصغيرة).
    static func present(
        types: [UTType],
        asCopy: Bool,
        allowsMultipleSelection: Bool,
        onPick: @escaping ([URL]) -> Void
    ) {
        guard let presenter = topViewController() else { return }

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: asCopy)
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.shouldShowFileExtensions = true

        let delegate = PickerDelegate(onPick: onPick)
        activeDelegate = delegate
        picker.delegate = delegate

        presenter.present(picker, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    fileprivate static func finish() {
        activeDelegate = nil
    }
}

@MainActor
private final class PickerDelegate: NSObject, UIDocumentPickerDelegate {

    private let onPick: ([URL]) -> Void

    init(onPick: @escaping ([URL]) -> Void) {
        self.onPick = onPick
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let handler = onPick
        DocumentPickerPresenter.finish()
        // بعد اكتمال إغلاق المنتقي، حتى لا تتزاحم العروض.
        DispatchQueue.main.async { handler(urls) }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        DocumentPickerPresenter.finish()
    }
}
