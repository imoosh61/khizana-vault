//
//  MediaViewerView.swift
//  SecureVault
//
//  معاينة بملء الشاشة: تمرير بين العناصر، تكبير الصور، تشغيل الفيديو، مشاركة، مفضلة، حذف.
//

import SwiftUI
import AVKit
import CoreData

struct MediaViewerView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var context

    @State private var items: [MediaItem]
    @State private var index: Int
    @State private var showDeleteConfirmation = false
    @State private var errorMessage: String?

    init(items: [MediaItem], startIndex: Int) {
        _items = State(initialValue: items)
        _index = State(initialValue: min(max(startIndex, 0), max(items.count - 1, 0)))
    }

    private var current: MediaItem? {
        items.indices.contains(index) ? items[index] : nil
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(items.enumerated()), id: \.element.objectID) { offset, item in
                    MediaPageView(item: item)
                        .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
        }
        .overlay(alignment: .top) { topBar }
        .overlay(alignment: .bottom) { bottomBar }
        .preferredColorScheme(.dark)
        .confirmationDialog("حذف هذا العنصر نهائياً من الخزنة؟", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("حذف", role: .destructive, action: deleteCurrent)
            Button("إلغاء", role: .cancel) {}
        }
        .alert("تعذّر الحذف", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("حسناً", role: .cancel) {}
        } message: {
            Text(verbatim: errorMessage ?? "")
        }
    }

    // MARK: الأشرطة

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }

            Spacer()

            if let current, current.managedObjectContext != nil {
                VStack(spacing: 2) {
                    Text(verbatim: "\(index + 1) / \(items.count)")
                        .font(.subheadline.bold())
                    Text(verbatim: "\(current.formattedSize) • \(current.createdAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
            Color.clear.frame(width: 40, height: 40)
        }
        .foregroundStyle(.white)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var bottomBar: some View {
        if let current, current.managedObjectContext != nil {
            HStack(spacing: 36) {
                Button {
                    toggleFavorite(current)
                } label: {
                    Image(systemName: current.isFavorite ? "heart.fill" : "heart")
                }

                ShareLink(item: current.fileURL) {
                    Image(systemName: "square.and.arrow.up")
                }

                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
            }
            .font(.title3)
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 12)
        }
    }

    // MARK: الإجراءات

    private func toggleFavorite(_ item: MediaItem) {
        item.isFavorite.toggle()
        do {
            try context.saveIfNeeded()
        } catch {
            context.rollback()
            errorMessage = error.localizedDescription
        }
    }

    private func deleteCurrent() {
        guard let item = current else { return }
        let fileName = item.fileName

        context.delete(item)
        do {
            try context.saveIfNeeded()
        } catch {
            context.rollback()
            errorMessage = error.localizedDescription
            return
        }
        MediaFileStore.removeFile(named: fileName)

        items.remove(at: index)
        if items.isEmpty {
            dismiss()
        } else {
            index = min(index, items.count - 1)
        }
    }
}

// MARK: - صفحة عنصر واحد

private struct MediaPageView: View {

    let item: MediaItem

    var body: some View {
        if item.managedObjectContext == nil || item.isDeleted {
            Color.clear
        } else if item.kind == .video {
            VideoPageView(url: item.fileURL)
        } else {
            ImagePageView(url: item.fileURL, placeholder: ThumbnailCache.shared.image(for: item))
        }
    }
}

private struct ImagePageView: View {

    let url: URL
    let placeholder: UIImage?

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                ZoomableImageView(image: image)
            } else if failed {
                Label("تعذّر تحميل الصورة", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else {
                if let placeholder {
                    Image(uiImage: placeholder)
                        .resizable()
                        .scaledToFit()
                }
                ProgressView().tint(.white)
            }
        }
        .task(id: url) {
            let loaded = await MediaFileStore.loadDisplayImage(at: url)
            if let loaded { image = loaded } else { failed = true }
        }
    }
}

private struct VideoPageView: View {

    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else {
                ProgressView().tint(.white)
            }
        }
        .onAppear {
            if player == nil { player = AVPlayer(url: url) }
        }
        .onDisappear {
            player?.pause()
        }
    }
}

// MARK: - تكبير الصورة (UIScrollView)

private struct ZoomableImageView: UIViewRepresentable {

    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.backgroundColor = .clear

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.frame = scrollView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView
        context.coordinator.scrollView = scrollView

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        if context.coordinator.imageView?.image !== image {
            context.coordinator.imageView?.image = image
            scrollView.zoomScale = 1
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        weak var scrollView: UIScrollView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }
            if scrollView.zoomScale > 1 {
                scrollView.setZoomScale(1, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let size = CGSize(
                    width: scrollView.bounds.width / 2.5,
                    height: scrollView.bounds.height / 2.5
                )
                let rect = CGRect(
                    x: point.x - size.width / 2,
                    y: point.y - size.height / 2,
                    width: size.width,
                    height: size.height
                )
                scrollView.zoom(to: rect, animated: true)
            }
        }
    }
}
