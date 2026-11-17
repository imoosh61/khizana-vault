//
//  NoteEditorView.swift
//  SecureVault
//
//  محرر واسع وخالٍ من المشتتات: حفظ تلقائي، تنسيق Markdown، ومعاينة.
//

import SwiftUI
import CoreData

struct NoteEditorView: View {

    private enum SaveState {
        case idle, pending, saved, failed
    }

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss

    /// الملاحظة الحالية. تبدأ `nil` في الملاحظة الجديدة وتُنشأ عند أول كتابة.
    @State private var current: Note?
    private let isSheet: Bool

    @State private var title: String
    @State private var bodyText: String
    @State private var tagsText: String
    @State private var isPinned: Bool

    @State private var showPreview = false
    @State private var saveState: SaveState = .idle
    @State private var saveTask: Task<Void, Never>?
    @State private var errorMessage: String?

    init(note: Note?) {
        _current = State(initialValue: note)
        isSheet = (note == nil)
        _title = State(initialValue: note?.title ?? "")
        _bodyText = State(initialValue: note?.body ?? "")
        _tagsText = State(initialValue: note?.tags.joined(separator: ", ") ?? "")
        _isPinned = State(initialValue: note?.isPinned ?? false)
    }

    private var hasContent: Bool {
        !title.trimmed.isEmpty || !bodyText.trimmed.isEmpty
    }

    private var parsedTags: [String] {
        tagsText
            .replacingOccurrences(of: "،", with: ",")
            .split(separator: ",")
            .map { String($0).trimmed }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("العنوان", text: $title, axis: .vertical)
                .font(.system(.title, design: .rounded).weight(.bold))
                .lineLimit(1...3)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 8)

            Divider().padding(.horizontal, 20)

            Group {
                if showPreview {
                    ScrollView {
                        MarkdownPreview(text: bodyText)
                            .padding(20)
                    }
                } else {
                    MarkdownTextView(text: $bodyText)
                }
            }
            .frame(maxHeight: .infinity)

            tagsBar
        }
        .vaultBackground()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                saveIndicator
            }

            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    showPreview.toggle()
                } label: {
                    Image(systemName: showPreview ? "pencil" : "eye")
                }
                .accessibilityLabel(Text("معاينة"))

                Button {
                    isPinned.toggle()
                } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                }
                .accessibilityLabel(Text("تثبيت"))

                if isSheet {
                    Button("تم") {
                        saveNow()
                        dismiss()
                    }
                    .bold()
                }
            }
        }
        .onChange(of: title) { _ in scheduleSave() }
        .onChange(of: bodyText) { _ in scheduleSave() }
        .onChange(of: tagsText) { _ in scheduleSave() }
        .onChange(of: isPinned) { _ in scheduleSave() }
        .onDisappear { saveNow() }
        .alert("تعذّر الحفظ", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("حسناً", role: .cancel) {}
        } message: {
            Text(verbatim: errorMessage ?? "")
        }
    }

    // MARK: الأجزاء

    private var tagsBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "tag")
                .foregroundStyle(.secondary)
            TextField("وسوم مفصولة بفواصل", text: $tagsText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Theme.card)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private var saveIndicator: some View {
        switch saveState {
        case .idle:
            EmptyView()
        case .pending:
            Label("جارٍ الحفظ…", systemImage: "ellipsis")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .saved:
            Label("تم الحفظ", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Theme.secure)
        case .failed:
            Label("فشل الحفظ", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    // MARK: الحفظ التلقائي

    private func scheduleSave() {
        saveState = .pending
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    private func saveNow() {
        saveTask?.cancel()

        if let note = current {
            guard note.managedObjectContext != nil, !note.isDeleted else { return }

            let changed = note.title != title
                || note.body != bodyText
                || note.tags != parsedTags
                || note.isPinned != isPinned
            guard changed else {
                if saveState == .pending { saveState = .saved }
                return
            }

            note.title = title
            note.body = bodyText
            note.tags = parsedTags
            note.isPinned = isPinned
            note.updatedAt = Date()
        } else {
            guard hasContent else {
                saveState = .idle
                return
            }
            current = Note.insert(in: context, title: title, body: bodyText, tags: parsedTags, isPinned: isPinned)
        }

        do {
            try context.saveIfNeeded()
            saveState = .saved
        } catch {
            context.rollback()
            saveState = .failed
            errorMessage = error.localizedDescription
        }
    }
}
