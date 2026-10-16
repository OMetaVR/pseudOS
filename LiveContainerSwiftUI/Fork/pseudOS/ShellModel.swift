//
//  ShellModel.swift
//  pseudOS
//
//  State shared by the home screen, the compositor and the system apps.
//

import SwiftUI
import Combine

enum SystemApp: String, CaseIterable, Codable {
    case settings, browser, store, library, files, gallery

    var name: String {
        switch self {
        case .settings: return "Settings"
        case .browser: return "Browser"
        case .store: return "App Store"
        case .library: return "Library"
        case .files: return "Files"
        case .gallery: return "Gallery"
        }
    }

    var glyph: PGlyph.Kind {
        switch self {
        case .settings: return .settings
        case .browser: return .browser
        case .store: return .store
        case .library: return .library
        case .files: return .files
        case .gallery: return .gallery
        }
    }
}

/// Something that can sit on the home screen: a stock app or an installed guest app (by its bundle folder name).
enum HomeItem: Hashable {
    case system(SystemApp)
    case guest(String)

    var key: String {
        switch self {
        case .system(let s): return "sys:" + s.rawValue
        case .guest(let path): return "app:" + path
        }
    }

    init?(key: String) {
        if key.hasPrefix("sys:"), let s = SystemApp(rawValue: String(key.dropFirst(4))) { self = .system(s) }
        else if key.hasPrefix("app:") { self = .guest(String(key.dropFirst(4))) }
        else { return nil }
    }
}

enum StoreTab: String, CaseIterable { case browse = "Browse", updates = "Updates", sources = "Sources" }
enum SettingsRoute: Hashable { case signing, appearance, multitasking, advanced, about }

final class ShellModel: ObservableObject {
    static let shared = ShellModel()

    // Layout
    @Published var pages: [[HomeItem]] = []
    @Published var dock: [HomeItem] = [.system(.browser), .system(.store), .system(.library), .system(.settings)]
    @Published var editing = false

    // Running state (keys are HomeItem.key), most recent first. Written by the compositor.
    @Published var running: [String] = []
    @Published var foreground: String?
    @Published var launching: Set<String> = []

    // System strip
    @Published var signedUntil: Date?
    @Published var toast: String?

    // Where stock apps should open to, set by chips and menus before opening them.
    @Published var storeTab: StoreTab = .browse
    @Published var settingsRoute: SettingsRoute?
    @Published var libraryFocus: String?

    /// Icon frames in window coordinates, so app windows can grow out of / shrink into their icons.
    var iconFrames: [String: CGRect] = [:]
    var isMounted = false
    private weak var compositorRef: AnyObject?
    private var bag = Set<AnyCancellable>()
    private var toastWork: DispatchWorkItem?

    static let columns = 4
    static let rowsPerPage = 6

    @available(iOS 16.0, *)
    var compositor: ShellCompositor? {
        get { compositorRef as? ShellCompositor }
        set { compositorRef = newValue }
    }

    private init() {
        loadLayout()
        DataManager.shared.model.$apps
            .receive(on: DispatchQueue.main)
            .sink { [weak self] apps in self?.reconcile(with: apps) }
            .store(in: &bag)
        signedUntil = Self.readProvisionExpiry()
    }

    // MARK: Apps

    func appModel(for path: String) -> LCAppModel? {
        DataManager.shared.model.apps.first { $0.appInfo.relativeBundlePath == path }
    }

    func appModel(dataUUID: String) -> LCAppModel? {
        DataManager.shared.model.apps.first { app in
            app.uiContainers.contains { $0.folderName == dataUUID } || app.appInfo.dataUUID == dataUUID
        }
    }

    func title(for item: HomeItem) -> String {
        switch item {
        case .system(let s): return s.name
        case .guest(let path): return appModel(for: path)?.displayName ?? path
        }
    }

    /// Adds newly installed apps to the end of the last page, drops uninstalled ones.
    private func reconcile(with apps: [LCAppModel]) {
        let installed = Set(apps.map { $0.appInfo.relativeBundlePath ?? "" })
        var placed = Set<String>()
        var newPages = pages.map { page in
            page.filter { item in
                if case .guest(let path) = item {
                    guard installed.contains(path) else { return false }
                    placed.insert(path)
                }
                return true
            }
        }
        dock = dock.filter { item in
            if case .guest(let path) = item {
                guard installed.contains(path) else { return false }
                placed.insert(path)
            }
            return true
        }
        let perPage = Self.columns * Self.rowsPerPage
        for app in apps where !(app.appInfo.isHidden) {
            guard let path = app.appInfo.relativeBundlePath, !placed.contains(path) else { continue }
            if newPages.isEmpty || newPages[newPages.count - 1].count >= perPage { newPages.append([]) }
            newPages[newPages.count - 1].append(.guest(path))
        }
        newPages.removeAll { $0.isEmpty }
        if newPages.isEmpty { newPages = [[]] }
        if newPages != pages {
            pages = newPages
            saveLayout()
        }
    }

    func remove(_ item: HomeItem) {
        pages = pages.map { $0.filter { $0 != item } }
        pages.removeAll { $0.isEmpty }
        if pages.isEmpty { pages = [[]] }
        saveLayout()
        showToast("Removed \(title(for: item)) from Home. It's still in Library.")
    }

    func move(_ item: HomeItem, toPage page: Int, index: Int) {
        guard page < pages.count else { return }
        var p = pages
        for i in p.indices { p[i].removeAll { $0 == item } }
        let idx = min(max(0, index), p[page].count)
        p[page].insert(item, at: idx)
        pages = p
    }

    // MARK: Persistence

    private static var layoutURL: URL {
        LCPath.docPath.appendingPathComponent("pseudOS/home.json")
    }

    private struct Stored: Codable { var pages: [[String]]; var dock: [String] }

    private func loadLayout() {
        if let data = try? Data(contentsOf: Self.layoutURL),
           let s = try? JSONDecoder().decode(Stored.self, from: data) {
            pages = s.pages.map { $0.compactMap(HomeItem.init(key:)) }
            let d = s.dock.compactMap(HomeItem.init(key:))
            if !d.isEmpty { dock = d }
        } else {
            pages = [[.system(.files), .system(.gallery)]]
        }
    }

    func saveLayout() {
        let s = Stored(pages: pages.map { $0.map(\.key) }, dock: dock.map(\.key))
        try? FileManager.default.createDirectory(at: Self.layoutURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: Self.layoutURL, options: .atomic) }
    }

    // MARK: Toasts

    func showToast(_ text: String) {
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { self.toast = text }
            self.toastWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                withAnimation(.easeOut(duration: 0.25)) { self?.toast = nil }
            }
            self.toastWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.8, execute: work)
        }
    }

    // MARK: Signing

    var signingDaysLeft: Int? {
        guard let until = signedUntil else { return nil }
        return max(0, Calendar.current.dateComponents([.day], from: Date(), to: until).day ?? 0)
    }

    /// Reads ExpirationDate from the app's own embedded.mobileprovision (a signed plist).
    static func readProvisionExpiry() -> Date? {
        let url = Bundle.main.bundleURL.appendingPathComponent("embedded.mobileprovision")
        guard let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        return plist?["ExpirationDate"] as? Date
    }

    func refreshSigningInfo() {
        signedUntil = Self.readProvisionExpiry()
    }
}
