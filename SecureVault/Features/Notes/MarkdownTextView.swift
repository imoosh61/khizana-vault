//
//  MarkdownTextView.swift
//  SecureVault
//
//  محرر نصي (UITextView) مع شريط تنسيق فوق لوحة المفاتيح يطبّق Markdown على التحديد الحالي،
//  ومعاينة تعرض التنسيق. (TextEditor في iOS 16 لا يكشف موضع المؤشر، لذلك نستخدم UIKit.)
//

import SwiftUI
import UIKit

struct MarkdownTextView: UIViewRepresentable {

    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 24, right: 12)
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.textAlignment = .natural
        textView.text = text
        textView.inputAccessoryView = context.coordinator.makeToolbar()
        context.coordinator.textView = textView
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        if textView.text != text {
            textView.text = text
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {

        var parent: MarkdownTextView
        weak var textView: UITextView?

        private static let listPrefixes = ["- [ ] ", "- [x] ", "- [X] ", "- "]

        init(_ parent: MarkdownTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        // MARK: الشريط

        func makeToolbar() -> UIToolbar {
            let toolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
            toolbar.tintColor = UIColor(Theme.accent)

            func item(_ symbol: String, _ action: Selector) -> UIBarButtonItem {
                UIBarButtonItem(image: UIImage(systemName: symbol), style: .plain, target: self, action: action)
            }

            toolbar.items = [
                item("bold", #selector(bold)),
                item("italic", #selector(italic)),
                item("textformat.size", #selector(heading)),
                item("list.bullet", #selector(bullet)),
                item("checklist", #selector(checklist)),
                UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
                item("keyboard.chevron.compact.down", #selector(dismissKeyboard))
            ]
            toolbar.sizeToFit()
            return toolbar
        }

        @objc private func bold() { wrap("**") }
        @objc private func italic() { wrap("_") }
        @objc private func heading() { toggleLinePrefix("## ", exclusiveWith: [], isList: false) }
        @objc private func bullet() { toggleLinePrefix("- ", exclusiveWith: Self.listPrefixes, isList: true) }
        @objc private func checklist() { toggleLinePrefix("- [ ] ", exclusiveWith: Self.listPrefixes, isList: true) }
        @objc private func dismissKeyboard() { textView?.resignFirstResponder() }

        // MARK: التنسيق

        /// يلفّ التحديد بعلامة (غامق/مائل)، أو يضع علامتين حول المؤشر عند عدم وجود تحديد.
        private func wrap(_ marker: String) {
            guard let textView else { return }
            let source = textView.text as NSString
            let range = textView.selectedRange
            let selected = source.substring(with: range)
            let replacement = marker + selected + marker
            let newText = source.replacingCharacters(in: range, with: replacement)

            let cursor = range.length == 0
                ? NSRange(location: range.location + (marker as NSString).length, length: 0)
                : NSRange(location: range.location, length: (replacement as NSString).length)
            apply(newText, selection: cursor)
        }

        /// يبدّل بادئة السطر الحالي (عنوان/نقطة/مهمة).
        private func toggleLinePrefix(_ prefix: String, exclusiveWith others: [String], isList: Bool) {
            guard let textView else { return }
            let source = textView.text as NSString
            let selection = textView.selectedRange
            let lineRange = source.lineRange(for: NSRange(location: selection.location, length: 0))
            let line = source.substring(with: lineRange)

            var newLine: String
            if line.hasPrefix(prefix) {
                newLine = String(line.dropFirst(prefix.count))
            } else {
                var stripped = line
                if isList {
                    for other in others.sorted(by: { $0.count > $1.count }) where stripped.hasPrefix(other) {
                        stripped.removeFirst(other.count)
                        break
                    }
                }
                newLine = prefix + stripped
            }

            let newText = source.replacingCharacters(in: lineRange, with: newLine)
            let delta = (newLine as NSString).length - (line as NSString).length
            let location = max(lineRange.location, selection.location + delta)
            apply(newText, selection: NSRange(location: location, length: 0))
        }

        private func apply(_ newText: String, selection: NSRange) {
            guard let textView else { return }
            textView.text = newText
            textView.selectedRange = selection
            parent.text = newText
        }
    }
}

// MARK: - المعاينة

struct MarkdownPreview: View {

    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                row(for: line)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(for line: String) -> some View {
        if line.hasPrefix("### ") {
            Text(inline(String(line.dropFirst(4)))).font(.headline)
        } else if line.hasPrefix("## ") {
            Text(inline(String(line.dropFirst(3)))).font(.title3.bold())
        } else if line.hasPrefix("# ") {
            Text(inline(String(line.dropFirst(2)))).font(.title2.bold())
        } else if line.hasPrefix("- [ ] ") {
            checkbox(checked: false, content: String(line.dropFirst(6)))
        } else if line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
            checkbox(checked: true, content: String(line.dropFirst(6)))
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "•").foregroundStyle(Theme.accent)
                Text(inline(String(line.dropFirst(2))))
            }
        } else if line.hasPrefix("> ") {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 3)
                Text(inline(String(line.dropFirst(2)))).foregroundStyle(.secondary)
            }
        } else if line.trimmed.isEmpty {
            Color.clear.frame(height: 6)
        } else {
            Text(inline(line))
        }
    }

    private func checkbox(checked: Bool, content: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(checked ? Theme.secure : .secondary)
            Text(inline(content))
                .strikethrough(checked)
                .foregroundStyle(checked ? .secondary : .primary)
        }
    }

    private func inline(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
    }
}
