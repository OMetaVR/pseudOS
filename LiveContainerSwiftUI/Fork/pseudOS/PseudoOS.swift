//
//  PseudoOS.swift
//  pseudOS (fork of LiveContainer, see FORK.md)
//
//  Entry points, preferences, theme and the bridge that upstream code calls into.
//

import SwiftUI
import CoreText

// MARK: - Preferences

enum PseudoAppearance: String, CaseIterable { case dark, light }

final class PseudoPrefs: ObservableObject {
    static let shared = PseudoPrefs()
    private let d = UserDefaults.standard

    /// Shows upstream's LiveContainer UI instead of the shell. Also settable with livecontainer://pseudos-classic.
    @Published var classicUI: Bool { didSet { d.set(classicUI, forKey: "pseudOS.classicUI") } }
    @Published var appearance: PseudoAppearance { didSet { d.set(appearance.rawValue, forKey: "pseudOS.appearance") } }
    @Published var accentHex: UInt32 { didSet { d.set(Int(accentHex), forKey: "pseudOS.accent") } }
    @Published var wallpaperSeed: UInt32 { didSet { d.set(Int(wallpaperSeed), forKey: "pseudOS.seed") } }
    @Published var runningLimit: Int { didSet { d.set(runningLimit, forKey: "pseudOS.runningLimit") } }
    @Published var autoRefresh: Bool { didSet { d.set(autoRefresh, forKey: "pseudOS.autoRefresh") } }

    private init() {
        classicUI = d.bool(forKey: "pseudOS.classicUI")
        appearance = PseudoAppearance(rawValue: d.string(forKey: "pseudOS.appearance") ?? "") ?? .dark
        accentHex = d.object(forKey: "pseudOS.accent") == nil ? 0xFFB000 : UInt32(d.integer(forKey: "pseudOS.accent"))
        if d.object(forKey: "pseudOS.seed") == nil {
            let seed = UInt32.random(in: 1...999_999)
            d.set(Int(seed), forKey: "pseudOS.seed")
            wallpaperSeed = seed
        } else {
            wallpaperSeed = UInt32(d.integer(forKey: "pseudOS.seed"))
        }
        runningLimit = d.object(forKey: "pseudOS.runningLimit") == nil ? 4 : d.integer(forKey: "pseudOS.runningLimit")
        autoRefresh = d.object(forKey: "pseudOS.autoRefresh") == nil ? true : d.bool(forKey: "pseudOS.autoRefresh")
    }

    static let accents: [UInt32] = [0xFFB000, 0x4FD1C5, 0xFF6B9A, 0x9DB4FF]
}

// MARK: - Theme

struct PTheme {
    let dark: Bool
    let accent: Color

    var base: Color { dark ? Color(hex: 0x1E2329) : Color(hex: 0xE9EDF1) }
    var appBackground: Color { dark ? Color(hex: 0x1A1E23) : Color(hex: 0xF2F4F7) }
    var row: Color { dark ? Color(hex: 0x232930) : .white }
    var surfaceSolid: Color { dark ? Color(hex: 0x262C33) : Color(hex: 0xF7F9FB) }
    var surfaceTint: Color { dark ? Color(hex: 0x2E353D).opacity(0.72) : Color.white.opacity(0.70) }
    var line: Color { dark ? Color(hex: 0xF3F5F7).opacity(0.08) : Color(hex: 0x1E2329).opacity(0.08) }
    var label: Color { dark ? Color(hex: 0xF3F5F7) : Color(hex: 0x1E2329) }
    var fog: Color { dark ? Color(hex: 0x9AA5B1) : Color(hex: 0x5B6673) }
    var alert: Color { dark ? Color(hex: 0xFF5A4F) : Color(hex: 0xD93A30) }
    /// The accent, darkened in light mode when it would be too pale on light surfaces.
    var signal: Color { accent }
    static let tileTop = Color(hex: 0x39414A)
    static let tileBottom = Color(hex: 0x2A3037)
    static let paper = Color(hex: 0xF3F5F7)
    static let ink = Color(hex: 0x1E2329)

    static func current(_ prefs: PseudoPrefs = .shared) -> PTheme {
        let dark = prefs.appearance == .dark
        var hex = prefs.accentHex
        if !dark && hex == 0xFFB000 { hex = 0xB87400 }
        return PTheme(dark: dark, accent: Color(hex: hex))
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

// MARK: - Fonts (Geist, SIL OFL; registered at runtime so Info.plist stays untouched)

enum PFont {
    private static var registered = false

    static func registerIfNeeded() {
        guard !registered else { return }
        registered = true
        let bundle = Bundle(for: ShellModel.self)
        for name in ["Geist-Light", "Geist-Regular", "Geist-Medium", "Geist-SemiBold"] {
            guard let url = bundle.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static func geist(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .light, .thin, .ultraLight: name = "Geist-Light"
        case .medium: name = "Geist-Medium"
        case .semibold, .bold, .heavy, .black: name = "Geist-SemiBold"
        default: name = "Geist-Regular"
        }
        if UIFont(name: name, size: size) != nil {
            return .custom(name, fixedSize: size)
        }
        return .system(size: size, weight: weight)
    }

    static func uiGeist(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
        let name: String
        switch weight {
        case .light, .thin, .ultraLight: name = "Geist-Light"
        case .medium: name = "Geist-Medium"
        case .semibold, .bold, .heavy, .black: name = "Geist-SemiBold"
        default: name = "Geist-Regular"
        }
        return UIFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }
}

// MARK: - Root

/// Chooses between the pseudOS shell and upstream's UI. The only call site is the FORK hook in LiveContainerSwiftUIApp.
struct PseudoOSRoot: View {
    @ObservedObject var prefs = PseudoPrefs.shared

    var body: some View {
        if #available(iOS 16.0, *), !prefs.classicUI {
            PseudoShellView()
        } else {
            LCTabView()
                .onOpenURL { url in
                    // Lets the shell be switched back on from the classic UI.
                    if url.host?.lowercased() == "pseudos-shell" { PseudoPrefs.shared.classicUI = false }
                }
        }
    }
}

// MARK: - Bridge used by the FORK hooks in upstream code

@objc(PseudoShellBridge)
final class PseudoShellBridge: NSObject {
    /// True while the shell is on screen. Upstream code falls back to its own behaviour when false.
    @objc static var isActive: Bool {
        if #available(iOS 16.0, *) { return ShellModel.shared.isMounted && !PseudoPrefs.shared.classicUI }
        return false
    }

    /// Called from LCUtils.launchMultitaskGuestApp instead of creating a DecoratedAppSceneViewController.
    @objc(launchGuestWithDisplayName:bundleId:dataUUID:completion:)
    static func launchGuest(displayName: String, bundleId: String, dataUUID: String, completion: ((NSNumber?, Error?) -> Void)?) {
        guard #available(iOS 16.0, *) else { completion?(nil, NSError(domain: "pseudOS", code: 1)); return }
        if let compositor = ShellModel.shared.compositor {
            compositor.launchGuest(displayName: displayName, bundleId: bundleId, dataUUID: dataUUID, completion: completion)
        } else {
            completion?(nil, NSError(domain: "pseudOS", code: 2, userInfo: [NSLocalizedDescriptionKey: "pseudOS isn't ready yet."]))
        }
    }

    /// Called from LCAppModel and the Library's Run button when an app may already be running.
    @objc(bringToFrontWithDataUUID:urlScheme:)
    static func bringToFront(dataUUID: String, urlScheme: String?) -> Bool {
        guard #available(iOS 16.0, *) else { return false }
        let found = ShellModel.shared.compositor?.bringGuestToFront(dataUUID: dataUUID, urlScheme: urlScheme) ?? false
        // The URL was delivered directly; don't leave it queued for the next app that launches.
        if found { UserDefaults.standard.removeObject(forKey: "launchAppUrlScheme") }
        return found
    }
}
