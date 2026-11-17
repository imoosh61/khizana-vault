//
//  NotesView.swift
//  SecureVault
//
//  الملاحظات: عرض شبكة أو قائمة، بحث، تثبيت، مفضلة وحذف.
//  الإضافة عبر الزر العائم (+).
//

import SwiftUI
import CoreData

enum NotesLayout: String, CaseIterable {
    case grid, list

    static let storageKey = "settings.notesLayout"
}

struct NotesView: View {

    @AppStorage(NotesLayout.storageKey) private var layoutRaw = NotesLayout.grid.rawValue
    @State private var searchText = ""

    private var layout: NotesLayout { NotesLayout(rawValue: layoutRaw) ?? .grid }

    var body: some View {
        NotesListContent(searchText: searchText, layout: layout)
            .vaultBackground()
            .navigationTitle("الملاحظات")
            .searchable(text: $searchText, prompt: Text("ابحث في العنوان والنص والوسوم"))
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        layoutRaw = (layout == .grid ? NotesLayout.list : NotesLayout.grid).rawValue
                    } label: {
                        Image(systemName: layout == .grid ? "list.bullet" : "square.grid.2x2")
                    }
                    .accessibilityLabel(Text("تغيير طريقة العرض"))
                }
            }
    }
}

// MARK: - المحتوى (استعلام ديناميكي حسب البحث)

private struct NotesListContent: View {

    @Environment(\.managedObjectContext) private var context
    @FetchRequest private var notes: FetchedResults<Note>

    let layout: NotesLayout
    private let isSearching: Bool

    @State private var errorMessage: String?

    init(searchText: String, layout: NotesLayout) {
        self.layout = layout

        let request = Note.request()
        request.sortDescriptors = [
            NSSortDescriptor(key: "isPinned", ascending: false),
            NSSortDescriptor(key: "updatedAt", ascending: false)
        ]

        let query = searchText.trimmed
        isSearching = !query.isEmpty
        if !query.isEmpty {
            request.predicate = NSPredicate(
                format: "title CONTAINS[cd] %@ OR body CONTAINS[cd] %@ OR tagsRaw CONTAINS[cd] %@",
                query, query, query
            )
        }
        _notes = FetchRequest(fetchRequest: request, animation: .default)
    }

    var body: some View {
        Group {
            switch layout {
            case .grid: gridView
            case .list: listView
            }
        }
        .overlay {
            if notes.isEmpty {
                if isSearching {
                    EmptyStateView(
                        systemImage: "magnifyingglass",
                        title: "لا توجد نتائج",
                        message: "جرّب كلمات بحث مختلفة."
                    )
                } else {
                    EmptyStateView(
                        systemImage: "note.text",
                        title: "لا توجد ملاحظات",
                        message: "اضغط على زر + لإضافة أول ملاحظة."
                    )
                }
            }
        }
        .alert("تعذّر الحفظ", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("حسناً", role: .cancel) {}
        } message: {
            Text(verbatim: errorMessage ?? "")
        }
    }

    // MARK: شبكة

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12, alignment: .top)], spacing: 12) {
                ForEach(notes, id: \.objectID) { note in
                    NavigationLink {
                        NoteEditorView(note: note)
                    } label: {
                        NoteCard(note: note)
                            .frame(minHeight: 130)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { actions(for: note) }
                }
            }
            .padding(16)
            .padding(.bottom, 90)   // مساحة للزر العائم
        }
    }

    // MARK: قائمة

    private var listView: some View {
        List {
            ForEach(notes, id: \.objectID) { note in
                NavigationLink {
                    NoteEditorView(note: note)
                } label: {
                    NoteCard(note: note, lineLimit: 2)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .swipeActions(edge: .leading) {
                    Button {
                        update(note) { $0.isPinned.toggle() }
                    } label: {
                        Label(note.isPinned ? LocalizedStringKey("إلغاء التثبيت") : LocalizedStringKey("تثبيت"), systemImage: note.isPinned ? "pin.slash" : "pin")
                    }
                    .tint(Theme.warning)

                    Button {
                        update(note) { $0.isFavorite.toggle() }
                    } label: {
                        Label("مفضلة", systemImage: note.isFavorite ? "star.slash" : "star")
                    }
                    .tint(.yellow)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        delete(note)
                    } label: {
                        Label("حذف", systemImage: "trash")
                    }
                }
            }
            Color.clear.frame(height: 70).listRowBackground(Color.clear).listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func actions(for note: Note) -> some View {
        Button {
            update(note) { $0.isPinned.toggle() }
        } label: {
            Label(note.isPinned ? LocalizedStringKey("إلغاء التثبيت") : LocalizedStringKey("تثبيت"), systemImage: note.isPinned ? "pin.slash" : "pin")
        }
        Button {
            update(note) { $0.isFavorite.toggle() }
        } label: {
            Label("مفضلة", systemImage: note.isFavorite ? "star.slash" : "star")
        }
        Button(role: .destructive) {
            delete(note)
        } label: {
            Label("حذف", systemImage: "trash")
        }
    }

    // MARK: التعديل

    private func update(_ note: Note, _ change: (Note) -> Void) {
        change(note)
        note.updatedAt = Date()
        persist()
    }

    private func delete(_ note: Note) {
        context.delete(note)
        persist()
    }

    private func persist() {
        do {
            try context.saveIfNeeded()
        } catch {
            context.rollback()
            errorMessage = error.localizedDescription
        }
    }
}
