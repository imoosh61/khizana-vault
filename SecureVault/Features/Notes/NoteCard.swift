//
//  NoteCard.swift
//  SecureVault
//
//  بطاقة ملاحظة قابلة لإعادة الاستخدام (قائمة، شبكة، ولوحة الملخّص).
//

import SwiftUI

struct NoteCard: View {

    @ObservedObject var note: Note
    var lineLimit = 4
    var showsTags = true

    var body: some View {
        if note.managedObjectContext == nil || note.isDeleted {
            Color.clear.frame(height: 1)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if note.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.warning)
                    }
                    Text(note.displayTitle)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if note.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }
                }

                if !note.previewText.isEmpty {
                    Text(note.previewText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(lineLimit)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    Text(note.updatedAt, style: .date)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    if showsTags {
                        ForEach(note.tags.prefix(2), id: \.self) { tag in
                            Text(verbatim: "#\(tag)")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.accent.opacity(0.16), in: Capsule())
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .vaultCard()
        }
    }
}
