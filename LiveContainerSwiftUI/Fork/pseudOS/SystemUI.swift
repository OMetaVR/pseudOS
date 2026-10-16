//
//  SystemUI.swift
//  pseudOS
//
//  Building blocks shared by the stock apps: grouped rows, headers, buttons, segmented control.
//

import SwiftUI

/// Hosting controller for stock apps, so their navigation bars can be styled without touching the Library's.
final class PSystemHost: UIHostingController<AnyView> {
    static func styleNavigationBars() {
        let bar = UINavigationBar.appearance(whenContainedInInstancesOf: [PSystemHost.self])
        let ink = UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0xF3F5F7) : UIColor(hex: 0x1E2329) }
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.largeTitleTextAttributes = [.font: PFont.uiGeist(32, .semibold), .foregroundColor: ink, .kern: -0.8]
        appearance.titleTextAttributes = [.font: PFont.uiGeist(17, .semibold), .foregroundColor: ink]
        let scrolled = UINavigationBarAppearance()
        scrolled.configureWithDefaultBackground()
        scrolled.titleTextAttributes = appearance.titleTextAttributes
        scrolled.largeTitleTextAttributes = appearance.largeTitleTextAttributes
        bar.standardAppearance = scrolled
        bar.compactAppearance = scrolled
        bar.scrollEdgeAppearance = appearance
        bar.prefersLargeTitles = true
    }
}

/// Picks the right stock app view.
@available(iOS 16.0, *)
struct SystemAppView: View {
    let app: SystemApp
    @EnvironmentObject var prefs: PseudoPrefs

    var body: some View {
        Group {
            switch app {
            case .settings: SettingsApp()
            case .store: StoreApp()
            case .browser: BrowserApp()
            case .files: FilesApp()
            case .gallery: GalleryApp()
            case .library: EmptyView()   // The Library is upstream's LCTabView, hosted by the compositor.
            }
        }
        .environment(\.font, PFont.geist(16))
    }
}

struct PGroup<Content: View>: View {
    let theme: PTheme
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) { content() }
            .background(theme.row, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(theme.dark ? 0.04 : 0)))
            .padding(.horizontal, 16)
    }
}

/// One row inside a PGroup; draws a hairline above every row but the first.
struct PRowContainer<Content: View>: View {
    let theme: PTheme
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(spacing: 12) { content() }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(minHeight: 52)
            .overlay(alignment: .top) { Rectangle().fill(theme.line).frame(height: 1).padding(.leading, 16) }
            .contentShape(Rectangle())
    }
}

/// Standard settings-style row: accent glyph, title, optional subtitle and value, chevron.
struct PRow: View {
    let theme: PTheme
    let glyph: PGlyph.Kind?
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    var chevron = true

    var body: some View {
        PRowContainer(theme: theme) {
            if let glyph {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(PTheme.tileTop)
                    PGlyph(kind: glyph, size: 18, accent: theme.signal)
                }
                .frame(width: 30, height: 30)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(PFont.geist(15.5, .medium)).foregroundStyle(theme.label)
                if let subtitle { Text(subtitle).font(PFont.geist(13)).foregroundStyle(theme.fog) }
            }
            Spacer(minLength: 8)
            if let value { Text(value).font(PFont.geist(15)).foregroundStyle(theme.fog) }
            if chevron { Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.fog.opacity(0.7)) }
        }
    }
}

struct PSectionHeader: View {
    let theme: PTheme
    let text: String
    var body: some View {
        Text(text)
            .font(PFont.geist(13, .medium))
            .foregroundStyle(theme.fog)
            .padding(.horizontal, 32)
            .padding(.top, 22)
            .padding(.bottom, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PEmpty: View {
    let theme: PTheme
    let text: String
    let action: (String, () -> Void)?
    var body: some View {
        VStack(spacing: 14) {
            Text(text)
                .font(PFont.geist(15))
                .foregroundStyle(theme.fog)
                .multilineTextAlignment(.center)
            if let action {
                Button(action.0, action: action.1).buttonStyle(PillButtonStyle(fill: theme.signal, text: PTheme.ink))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 30)
        .padding(.vertical, 40)
    }
}

struct TintButtonStyle: ButtonStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PFont.geist(13.5, .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(color.opacity(0.18), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct QuietButtonStyle: ButtonStyle {
    let theme: PTheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PFont.geist(13.5, .semibold))
            .foregroundStyle(theme.label)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(theme.line, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Segmented control with a sliding thumb (matched geometry), styled like the rest of the shell.
struct PSegmented<T: Hashable>: View {
    @Binding var selection: T
    let options: [T]
    let label: (T) -> String
    let theme: PTheme
    @Namespace private var ns

    init(selection: Binding<T>, options: [T], label: KeyPath<T, String>, theme: PTheme) {
        _selection = selection
        self.options = options
        self.label = { $0[keyPath: label] }
        self.theme = theme
    }

    init(selection: Binding<T>, options: [T], labelFn: @escaping (T) -> String, theme: PTheme) {
        _selection = selection
        self.options = options
        self.label = labelFn
        self.theme = theme
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let on = option == selection
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { selection = option }
                } label: {
                    Text(label(option))
                        .font(PFont.geist(14, .medium))
                        .foregroundStyle(on ? (theme.dark ? PTheme.paper : PTheme.ink) : theme.fog)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(theme.dark ? Color(hex: 0x2E353D) : .white)
                                    .shadow(color: .black.opacity(theme.dark ? 0 : 0.12), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "thumb", in: ns)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(theme.row, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
