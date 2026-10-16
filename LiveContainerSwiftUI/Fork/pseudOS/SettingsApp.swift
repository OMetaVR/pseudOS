//
//  SettingsApp.swift
//  pseudOS
//
//  Settings: signing (refresh through built-in SideStore), appearance, multitasking, and the way back
//  to LiveContainer's own settings and classic UI.
//

import SwiftUI

/// Runs built-in SideStore's refresh through PseudoRefreshBridge (SideStoreSupport/Fork), loaded at runtime.
enum SigningRefresher {
    static var isAvailable: Bool { NSClassFromString("PseudoRefreshBridge") != nil }

    static func refresh(progress: @escaping (Double) -> Void, completion: @escaping (String?) -> Void) {
        guard let cls = NSClassFromString("PseudoRefreshBridge") as? NSObject.Type else {
            completion("This copy of pseudOS doesn't include SideStore. Install the pseudOS+SideStore build to refresh from here.")
            return
        }
        let p: @convention(block) (Double) -> Void = { progress($0) }
        let c: @convention(block) (NSString?) -> Void = { completion($0 as String?) }
        _ = cls.perform(NSSelectorFromString("refreshWithProgress:completion:"),
                        with: unsafeBitCast(p, to: AnyObject.self),
                        with: unsafeBitCast(c, to: AnyObject.self))
    }

    /// Refreshes on its own when signing is about to run out, if the user allows it.
    static func refreshIfNeeded() {
        guard PseudoPrefs.shared.autoRefresh, isAvailable,
              let days = ShellModel.shared.signingDaysLeft, days <= 2 else { return }
        ShellModel.shared.showToast("Refreshing signing: \(days) day\(days == 1 ? "" : "s") left")
        refresh(progress: { _ in }) { error in
            ShellModel.shared.refreshSigningInfo()
            ShellModel.shared.showToast(error.map { "Refresh didn't finish: \($0)" } ?? "Signed for 7 days")
        }
    }
}

@available(iOS 16.0, *)
struct SettingsApp: View {
    @EnvironmentObject var model: ShellModel
    @EnvironmentObject var prefs: PseudoPrefs
    @State private var path: [SettingsRoute] = []
    @State private var confirmClassic = false

    private var theme: PTheme { PTheme.current(prefs) }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 0) {
                    PGroup(theme: theme) {
                        NavigationLink(value: SettingsRoute.signing) {
                            PRow(theme: theme, glyph: .sign, title: "Signing", value: model.signingDaysLeft.map { "\($0) days left" })
                        }
                        NavigationLink(value: SettingsRoute.appearance) {
                            PRow(theme: theme, glyph: .look, title: "Appearance", value: prefs.appearance == .dark ? "Dark" : "Light")
                        }
                        NavigationLink(value: SettingsRoute.multitasking) {
                            PRow(theme: theme, glyph: .multi, title: "Multitasking", value: "\(prefs.runningLimit) apps")
                        }
                    }
                    PSectionHeader(theme: theme, text: "LiveContainer")
                    PGroup(theme: theme) {
                        Button { openLibrary(tab: .apps) } label: {
                            PRow(theme: theme, glyph: .library, title: "Library", subtitle: "Install IPAs, containers, tweaks")
                        }
                        Button { openLibrary(tab: .settings) } label: {
                            PRow(theme: theme, glyph: .advanced, title: "Advanced", subtitle: "JIT, certificates, storage, developer options")
                        }
                    }
                    PSectionHeader(theme: theme, text: "pseudOS")
                    PGroup(theme: theme) {
                        Button { confirmClassic = true } label: {
                            PRow(theme: theme, glyph: .phone, title: "Use classic LiveContainer UI", subtitle: "Turn pseudOS back on from LiveContainer's Settings", chevron: false)
                        }
                        NavigationLink(value: SettingsRoute.about) {
                            PRow(theme: theme, glyph: .about, title: "About pseudOS", value: "Beta 1")
                        }
                    }
                }
                .buttonStyle(.plain)
                .padding(.bottom, 40)
            }
            .background(theme.appBackground.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .signing: SigningPage()
                case .appearance: AppearancePage()
                case .multitasking: MultitaskingPage()
                case .about, .advanced: AboutPage()
                }
            }
        }
        .tint(theme.signal)
        .confirmationDialog("Switch to the classic LiveContainer UI?", isPresented: $confirmClassic, titleVisibility: .visible) {
            Button("Use classic UI") {
                DataManager.shared.model.mainWindowOpened = false
                prefs.classicUI = true
            }
        } message: {
            Text("Running apps will close. To come back, open \(LCUtils.appUrlScheme() ?? "livecontainer")://pseudos-shell in Safari.")
        }
        .onAppear(perform: followRoute)
        .onChange(of: model.settingsRoute) { _ in followRoute() }
    }

    private func followRoute() {
        guard let route = model.settingsRoute else { return }
        path = [route]
        model.settingsRoute = nil
    }

    private func openLibrary(tab: LCTabIdentifier) {
        DataManager.shared.model.selectedTab = tab
        ShellModel.shared.compositor?.open(.system(.library), from: nil)
    }
}

// MARK: - Signing

@available(iOS 16.0, *)
private struct SigningPage: View {
    @EnvironmentObject var model: ShellModel
    @EnvironmentObject var prefs: PseudoPrefs
    @State private var refreshing = false
    @State private var progress: Double = 0
    @State private var error: String?
    @State private var certificateLine = "Checking…"

    private var theme: PTheme { PTheme.current(prefs) }
    private var days: Int { model.signingDaysLeft ?? 0 }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(model.signingDaysLeft.map(String.init) ?? "–")
                            .font(PFont.geist(44, .light)).kerning(-1.5).foregroundStyle(theme.label)
                            .contentTransition(.numericText())
                        Text(days == 1 ? "day left" : "days left").font(PFont.geist(17, .medium)).foregroundStyle(theme.fog)
                    }
                    Text(untilText).font(PFont.geist(14)).foregroundStyle(theme.fog)
                    HStack(spacing: 5) {
                        ForEach(0..<7, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(i < days ? (days <= 2 ? theme.alert : theme.signal) : theme.line)
                                .frame(height: 10)
                        }
                    }
                    .padding(.top, 14)
                    .animation(.spring(response: 0.5, dampingFraction: 0.8), value: days)
                    if refreshing {
                        ProgressView(value: progress).tint(theme.signal).padding(.top, 14)
                        Text(stepText).font(PFont.geist(13.5)).foregroundStyle(theme.fog).padding(.top, 6)
                    }
                    if let error {
                        Text(error).font(PFont.geist(13.5)).foregroundStyle(theme.alert).padding(.top, 10)
                    }
                    Button(refreshing ? "Refreshing…" : "Refresh now", action: refresh)
                        .buttonStyle(WideButtonStyle(fill: theme.signal))
                        .disabled(refreshing)
                        .padding(.top, 14)
                }
                .padding(18)
                .background(theme.row, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 16)

                PGroup(theme: theme) {
                    PRowContainer(theme: theme) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Refresh automatically").font(PFont.geist(15.5, .medium)).foregroundStyle(theme.label)
                            Text("When 2 days are left, while pseudOS is open").font(PFont.geist(13)).foregroundStyle(theme.fog)
                        }
                        Spacer()
                        Toggle("", isOn: $prefs.autoRefresh).labelsHidden().tint(theme.signal)
                    }
                }
                .padding(.top, 14)

                PSectionHeader(theme: theme, text: "Certificate and account")
                PGroup(theme: theme) {
                    PRow(theme: theme, glyph: .key, title: "Certificate", subtitle: certificateLine, chevron: false)
                    Button {
                        if UserDefaults.sideStoreExist() {
                            Task { try? await LCAppModel(appInfo: BuiltInSideStoreAppInfo.shared, delegate: nil)
                                .runApp(multitask: true, bundleIdOverride: "builtinSideStore") }
                        } else {
                            model.showToast("This copy of pseudOS doesn't include SideStore.")
                        }
                    } label: {
                        PRow(theme: theme, glyph: .store, title: "SideStore setup", subtitle: "Apple Account, pairing file, connection")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 40)
        }
        .background(theme.appBackground.ignoresSafeArea())
        .navigationTitle("Signing")
        .onAppear(perform: loadCertificate)
    }

    private var untilText: String {
        guard let until = model.signedUntil else { return "pseudOS couldn't read its signing date." }
        return "pseudOS is signed until \(until.formatted(.dateTime.weekday(.wide).day().month(.wide))). Refresh before then or it won't open."
    }

    private var stepText: String {
        switch progress {
        case ..<0.1: return "Starting SideStore"
        case ..<0.4: return "Connecting to this iPhone"
        case ..<0.9: return "Signing pseudOS"
        default: return "Installing"
        }
    }

    private func refresh() {
        error = nil
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { refreshing = true; progress = 0 }
        SigningRefresher.refresh(progress: { value in
            withAnimation(.easeOut(duration: 0.2)) { progress = value }
        }) { message in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                refreshing = false
                error = message
            }
            model.refreshSigningInfo()
            if message == nil { model.showToast("Signed for 7 days") }
        }
    }

    private func loadCertificate() {
        let updated = UserDefaults.lcShared().object(forKey: "LCCertificateUpdateDate") as? Date
        _ = LCUtils.validateCertificate { status, expiration, _, error in
            DispatchQueue.main.async {
                if let error, !error.isEmpty { certificateLine = "Not set up: \(error)"; return }
                var parts: [String] = []
                if status == 1 { parts.append("Revoked") }
                if let updated { parts.append("Imported \(updated.formatted(.dateTime.day().month(.wide)))") }
                if let expiration { parts.append("valid until \(expiration.formatted(.dateTime.day().month(.wide).year()))") }
                certificateLine = parts.isEmpty ? "Imported" : parts.joined(separator: ", ")
            }
        }
    }
}

struct WideButtonStyle: ButtonStyle {
    let fill: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PFont.geist(15, .semibold))
            .foregroundStyle(PTheme.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Appearance

@available(iOS 16.0, *)
private struct AppearancePage: View {
    @EnvironmentObject var prefs: PseudoPrefs
    private var theme: PTheme { PTheme.current(prefs) }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                PSegmented(selection: $prefs.appearance, options: PseudoAppearance.allCases,
                           labelFn: { $0 == .dark ? "Dark" : "Light" }, theme: theme)
                    .padding(.horizontal, 16)
                PSectionHeader(theme: theme, text: "Wallpaper")
                PGroup(theme: theme) {
                    Button {
                        prefs.wallpaperSeed = UInt32.random(in: 1...999_999)
                    } label: {
                        PRow(theme: theme, glyph: .wallpaper, title: "New terrain", subtitle: "Seed \(prefs.wallpaperSeed)", chevron: false)
                    }
                    .buttonStyle(.plain)
                }
                PSectionHeader(theme: theme, text: "Accent")
                PGroup(theme: theme) {
                    PRowContainer(theme: theme) {
                        ForEach(PseudoPrefs.accents, id: \.self) { hex in
                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { prefs.accentHex = hex }
                            } label: {
                                Circle().fill(Color(hex: hex)).frame(width: 30, height: 30)
                                    .overlay(Circle().strokeBorder(theme.appBackground, lineWidth: prefs.accentHex == hex ? 2 : 0).padding(-2))
                                    .overlay(Circle().strokeBorder(Color(hex: hex), lineWidth: prefs.accentHex == hex ? 2 : 0).padding(-4))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Accent")
                        }
                        Spacer()
                    }
                }
            }
            .padding(.bottom, 40)
        }
        .background(theme.appBackground.ignoresSafeArea())
        .navigationTitle("Appearance")
    }
}

// MARK: - Multitasking

@available(iOS 16.0, *)
private struct MultitaskingPage: View {
    @EnvironmentObject var prefs: PseudoPrefs
    private var theme: PTheme { PTheme.current(prefs) }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                PGroup(theme: theme) {
                    PRowContainer(theme: theme) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Running apps").font(PFont.geist(15.5, .medium)).foregroundStyle(theme.label)
                            Text("Opening one more closes the one you used longest ago").font(PFont.geist(13)).foregroundStyle(theme.fog)
                        }
                        Spacer(minLength: 8)
                        Stepper("\(prefs.runningLimit)", value: $prefs.runningLimit, in: 2...8)
                            .labelsHidden()
                        Text("\(prefs.runningLimit)").font(PFont.geist(16, .medium)).foregroundStyle(theme.label).frame(minWidth: 18)
                            .contentTransition(.numericText())
                    }
                }
                Text("Each running app is its own process. iOS closes pseudOS's apps when the phone runs low on memory, so a lower limit is more reliable.")
                    .font(PFont.geist(13)).foregroundStyle(theme.fog)
                    .padding(.horizontal, 32).padding(.top, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.bottom, 40)
        }
        .background(theme.appBackground.ignoresSafeArea())
        .navigationTitle("Multitasking")
    }
}

// MARK: - About

@available(iOS 16.0, *)
private struct AboutPage: View {
    @EnvironmentObject var prefs: PseudoPrefs
    @EnvironmentObject var model: ShellModel
    private var theme: PTheme { PTheme.current(prefs) }
    private var lcVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }

    var body: some View {
        ScrollView {
            PGroup(theme: theme) {
                PRow(theme: theme, glyph: nil, title: "pseudOS", value: "Beta 1", chevron: false)
                PRow(theme: theme, glyph: nil, title: "Built on LiveContainer", value: lcVersion, chevron: false)
                PRow(theme: theme, glyph: nil, title: "Running apps", value: "\(model.running.filter { $0.hasPrefix("app:") }.count) of \(prefs.runningLimit)", chevron: false)
            }
            .padding(.bottom, 40)
        }
        .background(theme.appBackground.ignoresSafeArea())
        .navigationTitle("About")
    }
}
