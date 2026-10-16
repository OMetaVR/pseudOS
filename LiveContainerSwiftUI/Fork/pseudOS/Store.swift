//
//  Store.swift
//  pseudOS
//
//  App Store: browse sources, install, and real updates for apps installed from a source.
//  Sources are upstream's (same list as the Library's Sources tab); installs go through upstream's pipeline.
//

import SwiftUI
import Combine

final class UpdateTracker: ObservableObject {
    static let shared = UpdateTracker()

    /// Where an installed app came from, and exactly which build was installed.
    struct Record: Codable, Equatable {
        var sourceURL: String
        var version: String
        var build: String?
        var sha256: String?
    }

    struct Update: Identifiable {
        var id: String { bundleId }
        let bundleId: String
        let name: String
        let installedVersion: String
        let latest: AltStoreSourceAppVersion
        let sha256: String?
        let rebuilt: Bool
        let sourceURL: URL
        let iconURL: URL?
    }

    struct Linkable: Identifiable {
        var id: String { bundleId + sourceURL.absoluteString }
        let bundleId: String
        let name: String
        let sourceName: String
        let sourceURL: URL
        let version: AltStoreSourceAppVersion
        let sha256: String?
    }

    @Published private(set) var available: [Update] = []
    @Published private(set) var linkable: [Linkable] = []
    @Published private(set) var lastChecked: Date?

    let sources = AltStoreSourcesViewModel()
    private var records: [String: Record] = [:]
    private var pending: [String: Record] = [:]
    private var bag = Set<AnyCancellable>()

    private static var recordsURL: URL { LCPath.docPath.appendingPathComponent("pseudOS/installs.json") }

    private init() {
        if let data = try? Data(contentsOf: Self.recordsURL),
           let r = try? JSONDecoder().decode([String: Record].self, from: data) { records = r }
        sources.$sources
            .combineLatest(DataManager.shared.model.$apps)
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.recompute() }
            .store(in: &bag)
    }

    func checkNow() async {
        await sources.refreshAllSources()
        await MainActor.run { lastChecked = Date(); recompute() }
    }

    func record(for bundleId: String) -> Record? { records[bundleId] }

    // MARK: Installed apps

    private func installed(_ bundleId: String) -> LCAppModel? {
        DataManager.shared.model.apps.first { $0.appInfo.bundleIdentifier() == bundleId }
    }

    private func installedBuild(_ app: LCAppModel) -> String? {
        guard let path = app.appInfo.bundlePath() else { return nil }
        return Bundle(path: path)?.infoDictionary?["CFBundleVersion"] as? String
    }

    /// The sha256 published for the newest version of an app, read from the source's cached JSON.
    private func publishedSHA(bundleId: String, in url: URL) -> String? {
        guard let data = sources.cachedData(for: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apps = json["apps"] as? [[String: Any]],
              let app = apps.first(where: { ($0["bundleIdentifier"] as? String) == bundleId }) else { return nil }
        if let versions = app["versions"] as? [[String: Any]], let first = versions.first, let sha = first["sha256"] as? String { return sha }
        return app["sha256"] as? String
    }

    private func recompute() {
        // Commit installs that have now landed.
        for (bid, rec) in pending {
            if let app = installed(bid), app.version == rec.version, rec.build == nil || installedBuild(app) == rec.build {
                records[bid] = rec
                pending[bid] = nil
                save()
            }
        }

        var updates: [Update] = []
        var links: [Linkable] = []
        for item in sources.sources {
            guard let source = item.source else { continue }
            for app in source.apps {
                guard let latest = app.latestVersion, let local = installed(app.bundleIdentifier) else { continue }
                let sha = publishedSHA(bundleId: app.bundleIdentifier, in: item.url)
                if let rec = records[app.bundleIdentifier] {
                    guard rec.sourceURL == item.url.absoluteString else { continue }
                    let localBuild = installedBuild(local)
                    let newVersion = latest.version != local.version
                    let newBuild = latest.buildVersion != nil && localBuild != nil && latest.buildVersion != localBuild
                    let rebuilt = !newVersion && !newBuild && sha != nil && rec.sha256 != nil && sha != rec.sha256
                    if newVersion || newBuild || rebuilt {
                        updates.append(Update(bundleId: app.bundleIdentifier, name: local.displayName, installedVersion: local.version,
                                              latest: latest, sha256: sha, rebuilt: rebuilt, sourceURL: item.url, iconURL: app.iconURL))
                    }
                } else {
                    links.append(Linkable(bundleId: app.bundleIdentifier, name: local.displayName, sourceName: source.name,
                                          sourceURL: item.url, version: latest, sha256: sha))
                }
            }
        }
        available = updates
        linkable = links
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.recordsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(records) { try? data.write(to: Self.recordsURL, options: .atomic) }
    }

    // MARK: Actions

    /// Treats an app installed some other way as coming from this source, at the build that's installed now.
    func link(_ l: Linkable) {
        guard let app = installed(l.bundleId) else { return }
        let sameBuild = l.version.version == app.version
        records[l.bundleId] = Record(sourceURL: l.sourceURL.absoluteString, version: app.version,
                                    build: installedBuild(app), sha256: sameBuild ? l.sha256 : nil)
        save()
        recompute()
    }

    func unlink(_ bundleId: String) {
        records[bundleId] = nil
        save()
        recompute()
    }

    /// Installs or updates through upstream's install pipeline in the Library (download, sign, replace prompt).
    func install(bundleId: String, version: AltStoreSourceAppVersion, sha256: String?, from sourceURL: URL) {
        pending[bundleId] = Record(sourceURL: sourceURL.absoluteString, version: version.version, build: version.buildVersion, sha256: sha256)
        if #available(iOS 16.0, *) {
            if let path = installed(bundleId)?.appInfo.relativeBundlePath {
                ShellModel.shared.compositor?.quit(key: HomeItem.guest(path).key)
            }
            DataManager.shared.model.selectedTab = .apps
            ShellModel.shared.compositor?.open(.system(.library), from: nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            NotificationCenter.default.post(name: NSNotification.InstallAppNotification, object: ["url": version.downloadURL])
        }
    }
}

// MARK: - App Store app

@available(iOS 16.0, *)
struct StoreApp: View {
    @EnvironmentObject var model: ShellModel
    @EnvironmentObject var prefs: PseudoPrefs
    @EnvironmentObject var tracker: UpdateTracker
    @ObservedObject private var sources = UpdateTracker.shared.sources
    @State private var newSource = ""
    @State private var addError: String?
    @State private var adding = false

    private var theme: PTheme { PTheme.current(prefs) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PSegmented(selection: $model.storeTab, options: StoreTab.allCases, label: \.rawValue, theme: theme)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                    switch model.storeTab {
                    case .browse: browse
                    case .updates: updatesView
                    case .sources: sourcesView
                    }
                }
                .padding(.bottom, 40)
            }
            .refreshable { await tracker.checkNow() }
            .background(theme.appBackground.ignoresSafeArea())
            .navigationTitle("App Store")
        }
        .tint(theme.signal)
    }

    // MARK: Browse

    @ViewBuilder private var browse: some View {
        if sources.sources.isEmpty {
            PEmpty(theme: theme, text: "Add a source to see its apps here.", action: ("Add a source", { model.storeTab = .sources }))
        }
        ForEach(sources.sources) { item in
            if let source = item.source {
                HStack(spacing: 12) {
                    RemoteIcon(url: source.iconURL, size: 44, radius: 12)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.name).font(PFont.geist(18, .semibold)).foregroundStyle(theme.label)
                        if let sub = source.subtitle { Text(sub).font(PFont.geist(13)).foregroundStyle(theme.fog) }
                    }
                }
                .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 10)
                PGroup(theme: theme) {
                    ForEach(source.apps) { app in
                        PRowContainer(theme: theme) {
                            RemoteIcon(url: app.iconURL, size: 34, radius: 9)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name).font(PFont.geist(15.5, .medium)).foregroundStyle(theme.label)
                                Text(app.latestVersion?.version ?? app.subtitle ?? "").font(PFont.geist(13)).foregroundStyle(theme.fog).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            actionButton(for: app, sourceURL: item.url)
                        }
                    }
                }
            } else if item.isLoading {
                ProgressView().frame(maxWidth: .infinity).padding(30)
            } else if let error = item.error {
                PEmpty(theme: theme, text: "\(item.displayName) couldn't be loaded: \(error)", action: nil)
            }
        }
    }

    @ViewBuilder private func actionButton(for app: AltStoreSourceApp, sourceURL: URL) -> some View {
        let installedApp = DataManager.shared.model.apps.first { $0.appInfo.bundleIdentifier() == app.bundleIdentifier }
        if let update = tracker.available.first(where: { $0.bundleId == app.bundleIdentifier }) {
            Button("Update") { tracker.install(bundleId: update.bundleId, version: update.latest, sha256: update.sha256, from: update.sourceURL) }
                .buttonStyle(TintButtonStyle(color: theme.signal))
        } else if let installedApp, let path = installedApp.appInfo.relativeBundlePath {
            Button("Open") { ShellModel.shared.compositor?.open(.guest(path), from: model.iconFrames[HomeItem.guest(path).key]) }
                .buttonStyle(QuietButtonStyle(theme: theme))
        } else if let latest = app.latestVersion {
            Button("Get") {
                tracker.install(bundleId: app.bundleIdentifier, version: latest, sha256: publishedSHA(app.bundleIdentifier, sourceURL), from: sourceURL)
            }
            .buttonStyle(TintButtonStyle(color: theme.signal))
        }
    }

    private func publishedSHA(_ bundleId: String, _ url: URL) -> String? {
        guard let data = tracker.sources.cachedData(for: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apps = json["apps"] as? [[String: Any]],
              let app = apps.first(where: { ($0["bundleIdentifier"] as? String) == bundleId }) else { return nil }
        return ((app["versions"] as? [[String: Any]])?.first?["sha256"] as? String) ?? app["sha256"] as? String
    }

    // MARK: Updates

    @ViewBuilder private var updatesView: some View {
        if tracker.available.isEmpty {
            PEmpty(theme: theme, text: "Everything is up to date.\npseudOS checks your sources each time it opens. Pull down to check now.", action: nil)
        } else {
            HStack {
                Text("\(tracker.available.count) update\(tracker.available.count == 1 ? "" : "s")")
                    .font(PFont.geist(20, .semibold)).foregroundStyle(theme.label)
                Spacer()
                Button("Update all") {
                    for u in tracker.available { tracker.install(bundleId: u.bundleId, version: u.latest, sha256: u.sha256, from: u.sourceURL) }
                }
                .buttonStyle(PillButtonStyle(fill: theme.signal, text: PTheme.ink))
            }
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 10)
            PGroup(theme: theme) {
                ForEach(tracker.available) { u in
                    PRowContainer(theme: theme) {
                        RemoteIcon(url: u.iconURL, size: 34, radius: 9)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(u.name).font(PFont.geist(15.5, .medium)).foregroundStyle(theme.label)
                            Text(u.rebuilt ? "\(u.latest.version), rebuilt" : "\(u.installedVersion) → \(u.latest.version)")
                                .font(PFont.geist(13)).foregroundStyle(theme.fog)
                            if u.rebuilt {
                                Text("Same version number, new build").font(PFont.geist(13)).foregroundStyle(theme.fog)
                            } else if let notes = u.latest.localizedDescription, !notes.isEmpty {
                                Text(notes).font(PFont.geist(13)).foregroundStyle(theme.fog).lineLimit(2)
                            }
                        }
                        Spacer(minLength: 8)
                        Button("Update") { tracker.install(bundleId: u.bundleId, version: u.latest, sha256: u.sha256, from: u.sourceURL) }
                            .buttonStyle(TintButtonStyle(color: theme.signal))
                    }
                }
            }
        }
        if !tracker.linkable.isEmpty {
            PSectionHeader(theme: theme, text: "Installed another way")
            PGroup(theme: theme) {
                ForEach(tracker.linkable) { l in
                    PRowContainer(theme: theme) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(l.name).font(PFont.geist(15.5, .medium)).foregroundStyle(theme.label)
                            Text("Also in \(l.sourceName). Link it to get updates from there.").font(PFont.geist(13)).foregroundStyle(theme.fog)
                        }
                        Spacer(minLength: 8)
                        Button("Link") { tracker.link(l) }.buttonStyle(QuietButtonStyle(theme: theme))
                    }
                }
            }
        }
        if let last = tracker.lastChecked {
            Text("Checked \(last.formatted(.relative(presentation: .named)))")
                .font(PFont.geist(13)).foregroundStyle(theme.fog)
                .padding(.horizontal, 32).padding(.top, 14)
        }
    }

    // MARK: Sources

    @ViewBuilder private var sourcesView: some View {
        PSectionHeader(theme: theme, text: "Your sources")
        if sources.sources.isEmpty {
            PEmpty(theme: theme, text: "No sources yet. Paste a source URL below.", action: nil)
        } else {
            PGroup(theme: theme) {
                ForEach(sources.sources) { item in
                    PRowContainer(theme: theme) {
                        RemoteIcon(url: item.primaryIconURL, size: 30, radius: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.displayName).font(PFont.geist(15.5, .medium)).foregroundStyle(theme.label)
                            Text(item.url.host ?? item.url.absoluteString).font(PFont.geist(13)).foregroundStyle(theme.fog).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if let count = item.source?.apps.count { Text("\(count) apps").font(PFont.geist(15)).foregroundStyle(theme.fog) }
                        Menu {
                            Button(role: .destructive) { sources.removeSource(item) } label: { Label("Remove source", systemImage: "trash") }
                        } label: {
                            Image(systemName: "ellipsis.circle").foregroundStyle(theme.fog).font(.system(size: 18))
                        }
                    }
                }
            }
        }
        PSectionHeader(theme: theme, text: "Add a source")
        HStack(spacing: 8) {
            TextField("https://…/source.json", text: $newSource)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(PFont.geist(15)).foregroundStyle(theme.label)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(theme.row, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Button(adding ? "Adding…" : "Add") {
                adding = true
                Task {
                    let error = await sources.addSource(from: newSource)
                    await MainActor.run {
                        adding = false
                        addError = error
                        if error == nil { newSource = ""; model.showToast("Source added. Its apps are in Browse.") }
                    }
                }
            }
            .buttonStyle(PillButtonStyle(fill: theme.signal, text: PTheme.ink))
            .disabled(newSource.isEmpty || adding)
        }
        .padding(.horizontal, 16)
        if let addError {
            Text(addError).font(PFont.geist(13)).foregroundStyle(theme.alert).padding(.horizontal, 32).padding(.top, 8)
        }
    }
}

/// Small remote image with the shell's corner style.
@available(iOS 16.0, *)
struct RemoteIcon: View {
    let url: URL?
    let size: CGFloat
    let radius: CGFloat
    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image { image.resizable().scaledToFill() } else { PTheme.tileBottom }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
