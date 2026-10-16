//
//  Apps.swift
//  pseudOS
//
//  Browser, Files and Gallery.
//

import SwiftUI
import WebKit
import Photos
import QuickLook

// MARK: - Browser

@available(iOS 16.0, *)
final class BrowserModel: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    @Published var url: URL?
    @Published var title = ""
    @Published var progress: Double = 0
    @Published var canGoBack = false
    @Published var canGoForward = false
    private var observations: [NSKeyValueObservation] = []

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observations = [
            webView.observe(\.url) { [weak self] w, _ in DispatchQueue.main.async { self?.url = w.url } },
            webView.observe(\.title) { [weak self] w, _ in DispatchQueue.main.async { self?.title = w.title ?? "" } },
            webView.observe(\.estimatedProgress) { [weak self] w, _ in DispatchQueue.main.async { self?.progress = w.estimatedProgress } },
            webView.observe(\.canGoBack) { [weak self] w, _ in DispatchQueue.main.async { self?.canGoBack = w.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] w, _ in DispatchQueue.main.async { self?.canGoForward = w.canGoForward } },
        ]
        load("https://github.com/OMetaVR/pseudOS")
    }

    func load(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let target: URL?
        if trimmed.contains("://") { target = URL(string: trimmed) }
        else if trimmed.contains("."), !trimmed.contains(" ") { target = URL(string: "https://" + trimmed) }
        else {
            var c = URLComponents(string: "https://duckduckgo.com/")!
            c.queryItems = [URLQueryItem(name: "q", value: trimmed)]
            target = c.url
        }
        if let target { webView.load(URLRequest(url: target)) }
    }

    /// Links for other apps (their URL schemes, livecontainer://, sources) leave the browser.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = action.request.url, let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "data", "blob", "file"].contains(scheme) {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

@available(iOS 16.0, *)
private struct WebViewHost: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

@available(iOS 16.0, *)
struct BrowserApp: View {
    @EnvironmentObject var prefs: PseudoPrefs
    @StateObject private var browser = BrowserModel()
    @State private var editing = false
    @State private var address = ""
    @FocusState private var focused: Bool
    private var theme: PTheme { PTheme.current(prefs) }

    var body: some View {
        ZStack(alignment: .bottom) {
            WebViewHost(webView: browser.webView)
                .ignoresSafeArea(edges: .bottom)
            VStack(spacing: 0) {
                if browser.progress < 1 {
                    ProgressView(value: browser.progress).tint(theme.signal).frame(height: 2)
                }
                HStack(spacing: 4) {
                    barButton("chevron.left", enabled: browser.canGoBack) { browser.webView.goBack() }
                    barButton("chevron.right", enabled: browser.canGoForward) { browser.webView.goForward() }
                    Group {
                        if editing {
                            TextField("Search or enter address", text: $address)
                                .focused($focused)
                                .keyboardType(.webSearch).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .submitLabel(.go)
                                .onSubmit { browser.load(address); editing = false }
                        } else {
                            Button {
                                address = browser.url?.absoluteString ?? ""
                                editing = true
                                focused = true
                            } label: {
                                HStack(spacing: 5) {
                                    if browser.url?.scheme == "https" { Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(theme.fog) }
                                    Text(browser.url?.host ?? "Search or enter address").lineLimit(1)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .font(PFont.geist(15))
                    .foregroundStyle(theme.label)
                    .frame(maxWidth: .infinity)
                    barButton("arrow.clockwise", enabled: true) { browser.webView.reload() }
                    if let url = browser.url {
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up").frame(width: 34, height: 34) }
                            .foregroundStyle(theme.label)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 50)
            }
            .background(theme.surfaceSolid, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(PBevel(cornerRadius: 16).opacity(0.5))
            .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
            .padding(.horizontal, 12)
            .padding(.bottom, 34)
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: editing)
        }
        .background(theme.appBackground.ignoresSafeArea())
    }

    private func barButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16, weight: .medium)).frame(width: 34, height: 34)
        }
        .foregroundStyle(enabled ? theme.label : theme.fog.opacity(0.4))
        .disabled(!enabled)
    }
}

// MARK: - Files

@available(iOS 16.0, *)
struct FilesApp: View {
    @EnvironmentObject var prefs: PseudoPrefs
    @EnvironmentObject var model: ShellModel
    private var theme: PTheme { PTheme.current(prefs) }

    private var containers: [(name: String, url: URL)] {
        let fm = FileManager.default
        var out: [(String, URL)] = []
        for base in [LCPath.dataPath, LCPath.lcGroupDataPath] {
            let items = (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
            for url in items where url.hasDirectoryPath {
                let uuid = url.lastPathComponent
                let app = model.appModel(dataUUID: uuid)
                let containerName = app?.uiContainers.first { $0.folderName == uuid }?.name
                let name = [app?.displayName, containerName].compactMap { $0 }.joined(separator: " – ")
                out.append((name.isEmpty ? uuid : name, url))
            }
        }
        return out.sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    PSectionHeader(theme: theme, text: "App data")
                    PGroup(theme: theme) {
                        ForEach(containers, id: \.url) { c in
                            NavigationLink { FolderView(url: c.url, title: c.name) } label: {
                                PRow(theme: theme, glyph: .files, title: c.name)
                            }
                        }
                    }
                    PSectionHeader(theme: theme, text: "pseudOS")
                    PGroup(theme: theme) {
                        NavigationLink { FolderView(url: LCPath.tweakPath, title: "Tweaks") } label: {
                            PRow(theme: theme, glyph: .advanced, title: "Tweaks")
                        }
                        NavigationLink { FolderView(url: LCPath.docPath.appendingPathComponent("Inbox"), title: "Inbox") } label: {
                            PRow(theme: theme, glyph: .files, title: "Inbox", subtitle: "Files shared to pseudOS")
                        }
                        NavigationLink { FolderView(url: LCPath.docPath, title: "Documents") } label: {
                            PRow(theme: theme, glyph: .files, title: "Everything", subtitle: "pseudOS's whole Documents folder")
                        }
                    }
                }
                .buttonStyle(.plain)
                .padding(.bottom, 40)
            }
            .background(theme.appBackground.ignoresSafeArea())
            .navigationTitle("Files")
        }
        .tint(theme.signal)
    }
}

@available(iOS 16.0, *)
private struct FolderView: View {
    let url: URL
    let title: String
    @EnvironmentObject var prefs: PseudoPrefs
    @State private var items: [URL] = []
    @State private var preview: URL?
    @State private var toDelete: URL?
    private var theme: PTheme { PTheme.current(prefs) }

    var body: some View {
        ScrollView {
            if items.isEmpty {
                PEmpty(theme: theme, text: "This folder is empty.", action: nil)
            } else {
                PGroup(theme: theme) {
                    ForEach(items, id: \.self) { item in
                        let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                        Group {
                            if isDir {
                                NavigationLink { FolderView(url: item, title: item.lastPathComponent) } label: {
                                    PRow(theme: theme, glyph: .files, title: item.lastPathComponent)
                                }
                            } else {
                                Button { preview = item } label: {
                                    PRow(theme: theme, glyph: nil, title: item.lastPathComponent, value: sizeText(item), chevron: false)
                                }
                            }
                        }
                        .contextMenu {
                            ShareLink(item: item) { Label("Share", systemImage: "square.and.arrow.up") }
                            Button(role: .destructive) { toDelete = item } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 8)
            }
        }
        .background(theme.appBackground.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .sheet(item: Binding(get: { preview.map(IdentifiedURL.init) }, set: { preview = $0?.url })) { p in
            QuickLookView(url: p.url).ignoresSafeArea()
        }
        .confirmationDialog("Delete \(toDelete?.lastPathComponent ?? "")?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let toDelete { try? FileManager.default.removeItem(at: toDelete) }
                toDelete = nil
                reload()
            }
        } message: {
            Text("This can't be undone.")
        }
    }

    private func reload() {
        let list = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])) ?? []
        items = list.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func sizeText(_ url: URL) -> String? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

private struct IdentifiedURL: Identifiable { let url: URL; var id: URL { url } }

private struct QuickLookView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UINavigationController {
        let ql = QLPreviewController()
        ql.dataSource = context.coordinator
        return UINavigationController(rootViewController: ql)
    }
    func updateUIViewController(_ vc: UINavigationController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

// MARK: - Gallery

@available(iOS 16.0, *)
final class GalleryModel: ObservableObject {
    @Published var status: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published var assets: [PHAsset] = []
    let manager = PHCachingImageManager()

    func load() {
        if status == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { s in
                DispatchQueue.main.async { self.status = s; self.fetch() }
            }
        } else {
            fetch()
        }
    }

    private func fetch() {
        guard status == .authorized || status == .limited else { return }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: options)
        var list: [PHAsset] = []
        list.reserveCapacity(result.count)
        result.enumerateObjects { a, _, _ in list.append(a) }
        assets = list
    }
}

@available(iOS 16.0, *)
struct GalleryApp: View {
    @EnvironmentObject var prefs: PseudoPrefs
    @StateObject private var gallery = GalleryModel()
    @State private var selected: PHAsset?
    private var theme: PTheme { PTheme.current(prefs) }

    var body: some View {
        NavigationStack {
            ScrollView {
                if gallery.status == .denied || gallery.status == .restricted {
                    PEmpty(theme: theme, text: "pseudOS can't see your photos. Allow access in the Settings app, under pseudOS > Photos.",
                           action: ("Open Settings", { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }))
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                        ForEach(gallery.assets, id: \.localIdentifier) { asset in
                            Thumbnail(asset: asset, manager: gallery.manager)
                                .aspectRatio(1, contentMode: .fill)
                                .clipped()
                                .contentShape(Rectangle())
                                .onTapGesture { selected = asset }
                        }
                    }
                    .padding(.bottom, 40)
                }
            }
            .background(theme.appBackground.ignoresSafeArea())
            .navigationTitle("Gallery")
        }
        .tint(theme.signal)
        .onAppear { gallery.load() }
        .fullScreenCover(item: Binding(get: { selected.map(IdentifiedAsset.init) }, set: { selected = $0?.asset })) { a in
            PhotoViewer(asset: a.asset, manager: gallery.manager) { selected = nil }
        }
    }
}

private struct IdentifiedAsset: Identifiable { let asset: PHAsset; var id: String { asset.localIdentifier } }

@available(iOS 16.0, *)
private struct Thumbnail: View {
    let asset: PHAsset
    let manager: PHCachingImageManager
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                PTheme.tileBottom
                if let image { Image(uiImage: image).resizable().scaledToFill().frame(width: geo.size.width, height: geo.size.width).clipped() }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear {
            let size = CGSize(width: 240, height: 240)
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = true
            manager.requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { img, _ in image = img }
        }
    }
}

@available(iOS 16.0, *)
private struct PhotoViewer: View {
    let asset: PHAsset
    let manager: PHCachingImageManager
    let close: () -> Void
    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var drag: CGSize = .zero

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(1 - min(0.6, abs(drag.height) / 400)).ignoresSafeArea()
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .scaleEffect(scale)
                    .offset(drag)
                    .gesture(MagnificationGesture().onChanged { scale = max(1, $0) }.onEnded { _ in
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { if scale < 1.1 { scale = 1 } }
                    })
                    .simultaneousGesture(DragGesture().onChanged { v in if scale == 1 { drag = v.translation } }.onEnded { v in
                        if abs(v.translation.height) > 140 { close() } else { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { drag = .zero } }
                    })
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 14) {
                if let image {
                    ShareLink(item: Image(uiImage: image), preview: SharePreview("Photo", image: Image(uiImage: image))) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                Button(action: close) { Image(systemName: "xmark") }
            }
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .padding(12)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.trailing, 16)
            .padding(.top, 8)
        }
        .onAppear {
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            manager.requestImage(for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .aspectFit, options: options) { img, _ in
                if let img { image = img }
            }
        }
    }
}
