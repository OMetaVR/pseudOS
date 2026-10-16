//
//  HomeView.swift
//  pseudOS
//
//  Clock, system strip, paged icon grid, page dots and dock.
//

import SwiftUI

@available(iOS 16.0, *)
struct HomeView: View {
    let openItem: (HomeItem, CGRect?) -> Void
    let openSwitcher: () -> Void

    @EnvironmentObject var model: ShellModel
    @EnvironmentObject var prefs: PseudoPrefs
    @EnvironmentObject var updates: UpdateTracker

    @State private var page = 0
    @State private var dragX: CGFloat = 0
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) private var darkModeIcon = false

    private var theme: PTheme { PTheme.current(prefs) }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            VStack(alignment: .leading, spacing: 0) {
                ClockView(theme: theme)
                    .padding(.leading, 26)
                    .padding(.top, 18)
                SystemStrip(theme: theme, openItem: openItem, openSwitcher: openSwitcher)
                    .padding(.top, 22)
                pager(width: width)
                    .padding(.top, 22)
                PageDots(count: model.pages.count, progress: progress(width: width), theme: theme)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 14)
                DockView(theme: theme, openItem: openItem, darkIcon: darkModeIcon)
                    .padding(.horizontal, 12)
                    .padding(.bottom, max(geo.safeAreaInsets.bottom, 12) + 4)
            }
            .overlay(alignment: .topTrailing) {
                if model.editing {
                    Button("Done") {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { model.editing = false }
                        model.saveLayout()
                    }
                    .buttonStyle(PillButtonStyle(fill: theme.signal, text: PTheme.ink))
                    .padding(.trailing, 18)
                    .padding(.top, 8)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
    }

    // MARK: Pager

    private func progress(width: CGFloat) -> CGFloat {
        guard width > 0 else { return CGFloat(page) }
        return CGFloat(page) - dragX / width
    }

    private func pager(width: CGFloat) -> some View {
        let count = max(1, model.pages.count)
        return HStack(spacing: 0) {
            ForEach(Array(model.pages.enumerated()), id: \.offset) { index, items in
                IconPage(items: items, pageIndex: index, theme: theme, darkIcon: darkModeIcon, openItem: openItem)
                    .frame(width: width)
            }
        }
        .frame(width: width, alignment: .leading)
        .offset(x: -CGFloat(page) * width + dragX)
        .frame(maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 14)
                .onChanged { v in
                    guard !model.editing || abs(v.translation.width) > abs(v.translation.height) else { return }
                    var x = v.translation.width
                    if (page == 0 && x > 0) || (page == count - 1 && x < 0) { x *= 0.35 }
                    dragX = x
                }
                .onEnded { v in
                    let predicted = v.predictedEndTranslation.width
                    var target = page
                    if predicted < -width / 2 { target += 1 } else if predicted > width / 2 { target -= 1 }
                    target = min(max(0, target), count - 1)
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                        page = target
                        dragX = 0
                    }
                }
        )
        .onChange(of: model.pages.count) { newCount in
            if page >= newCount { page = max(0, newCount - 1) }
        }
    }
}

// MARK: - Clock

@available(iOS 16.0, *)
private struct ClockView: View {
    let theme: PTheme
    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 8) {
                Text(context.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                    .font(PFont.geist(76, .light))
                    .monospacedDigit()
                    .kerning(-3)
                    .foregroundStyle(theme.label)
                Text(context.date, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(PFont.geist(15, .medium))
                    .foregroundStyle(theme.fog)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - System strip

@available(iOS 16.0, *)
private struct SystemStrip: View {
    let theme: PTheme
    let openItem: (HomeItem, CGRect?) -> Void
    let openSwitcher: () -> Void
    @EnvironmentObject var model: ShellModel
    @EnvironmentObject var updates: UpdateTracker

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if updates.available.count > 0 {
                    Chip(theme: theme, dot: theme.signal, text: "\(updates.available.count) update\(updates.available.count == 1 ? "" : "s")") {
                        model.storeTab = .updates
                        openItem(.system(.store), model.iconFrames[HomeItem.system(.store).key])
                    }
                }
                let guests = model.running.filter { $0.hasPrefix("app:") }.count
                if guests > 0 {
                    Chip(theme: theme, dot: nil, text: "\(guests) running", action: openSwitcher)
                }
                if let days = model.signingDaysLeft {
                    Chip(theme: theme, dot: days <= 2 ? theme.alert : nil, text: "Signed for \(days) day\(days == 1 ? "" : "s")") {
                        model.settingsRoute = .signing
                        openItem(.system(.settings), model.iconFrames[HomeItem.system(.settings).key])
                    }
                }
            }
            .padding(.horizontal, 22)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: updates.available.count)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.running)
        }
    }
}

@available(iOS 16.0, *)
private struct Chip: View {
    let theme: PTheme
    let dot: Color?
    let text: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
                Text(text).font(PFont.geist(12.5, .medium)).foregroundStyle(theme.label)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background(theme.surfaceTint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.06)))
        }
        .buttonStyle(PressScaleStyle())
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }
}

// MARK: - Icons

@available(iOS 16.0, *)
private struct IconPage: View {
    let items: [HomeItem]
    let pageIndex: Int
    let theme: PTheme
    let darkIcon: Bool
    let openItem: (HomeItem, CGRect?) -> Void
    @EnvironmentObject var model: ShellModel
    @State private var draggingKey: String?
    @State private var dragOffset: CGSize = .zero
    @State private var dragOrigin: CGPoint = .zero

    var body: some View {
        GeometryReader { geo in
            let cellW = (geo.size.width - 36) / CGFloat(ShellModel.columns)
            let cellH: CGFloat = 96
            ZStack(alignment: .topLeading) {
                ForEach(Array(items.enumerated()), id: \.element) { index, item in
                    let col = index % ShellModel.columns, row = index / ShellModel.columns
                    let dragging = draggingKey == item.key
                    HomeIcon(item: item, theme: theme, darkIcon: darkIcon, showLabel: true, openItem: openItem)
                        .frame(width: cellW, height: cellH)
                        .scaleEffect(dragging ? 1.12 : 1)
                        .zIndex(dragging ? 1 : 0)
                        .position(x: 18 + cellW * (CGFloat(col) + 0.5), y: cellH * (CGFloat(row) + 0.5))
                        .offset(dragging ? dragOffset : .zero)
                        .highPriorityGesture(editDrag(item: item, index: index, cellW: cellW, cellH: cellH), including: model.editing ? .all : .subviews)
                }
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.82), value: items)
        }
    }

    private func slotCenter(_ index: Int, cellW: CGFloat, cellH: CGFloat) -> CGPoint {
        let col = index % ShellModel.columns, row = index / ShellModel.columns
        return CGPoint(x: 18 + cellW * (CGFloat(col) + 0.5), y: cellH * (CGFloat(row) + 0.5))
    }

    private func editDrag(item: HomeItem, index: Int, cellW: CGFloat, cellH: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                guard model.editing else { return }
                if draggingKey == nil {
                    draggingKey = item.key
                    dragOrigin = slotCenter(index, cellW: cellW, cellH: cellH)
                }
                guard draggingKey == item.key, let current = items.firstIndex(of: item) else { return }
                // Where the finger has carried the icon, measured from the slot it started in.
                let finger = CGPoint(x: dragOrigin.x + v.translation.width, y: dragOrigin.y + v.translation.height)
                let slot = slotCenter(current, cellW: cellW, cellH: cellH)
                dragOffset = CGSize(width: finger.x - slot.x, height: finger.y - slot.y)
                let targetCol = min(max(0, Int((finger.x - 18) / cellW)), ShellModel.columns - 1)
                let targetRow = max(0, Int(finger.y / cellH))
                let target = min(targetRow * ShellModel.columns + targetCol, items.count - 1)
                if target != current {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                        model.move(item, toPage: pageIndex, index: target)
                    }
                    let newSlot = slotCenter(target, cellW: cellW, cellH: cellH)
                    dragOffset = CGSize(width: finger.x - newSlot.x, height: finger.y - newSlot.y)
                    UISelectionFeedbackGenerator().selectionChanged()
                }
            }
            .onEnded { _ in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    draggingKey = nil
                    dragOffset = .zero
                }
                model.saveLayout()
            }
    }
}

@available(iOS 16.0, *)
struct HomeIcon: View {
    let item: HomeItem
    let theme: PTheme
    let darkIcon: Bool
    let showLabel: Bool
    let openItem: (HomeItem, CGRect?) -> Void
    @EnvironmentObject var model: ShellModel
    @EnvironmentObject var updates: UpdateTracker
    @State private var frame: CGRect = .zero

    private var isRunning: Bool { model.running.contains(item.key) }
    private var isLaunching: Bool { model.launching.contains(item.key) }

    var body: some View {
        Button {
            if model.editing { return }
            openItem(item, frame == .zero ? nil : frame)
        } label: {
            VStack(spacing: 7) {
                ZStack(alignment: .topTrailing) {
                    PAppIcon(item: item, size: 60, accent: theme.signal, darkIcon: darkIcon)
                        .overlay {
                            if isLaunching {
                                RoundedRectangle(cornerRadius: 15, style: .continuous).fill(.black.opacity(0.45))
                                ProgressView().tint(.white)
                            }
                        }
                        .background(GeometryReader { proxy in
                            Color.clear
                                .onAppear { report(proxy.frame(in: .global)) }
                                .onChange(of: proxy.frame(in: .global)) { report($0) }
                        })
                        .overlay(alignment: .topLeading) {
                            if model.editing, case .guest = item {
                                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.remove(item) } } label: {
                                    Image(systemName: "minus")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(PTheme.ink)
                                        .frame(width: 22, height: 22)
                                        .background(theme.fog, in: Circle())
                                }
                                .offset(x: -7, y: -7)
                                .transition(.scale.combined(with: .opacity))
                            }
                        }
                    if item == .system(.store), updates.available.count > 0 {
                        Text("\(updates.available.count)")
                            .font(PFont.geist(12, .semibold))
                            .foregroundStyle(PTheme.ink)
                            .padding(.horizontal, 6)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(theme.signal, in: Capsule())
                            .offset(x: 6, y: -5)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                if showLabel {
                    Text(model.title(for: item))
                        .font(PFont.geist(11.5, .medium))
                        .foregroundStyle(theme.label)
                        .shadow(color: theme.dark ? .black.opacity(0.6) : .clear, radius: 3, y: 1)
                        .lineLimit(1)
                        .frame(maxWidth: 76)
                }
                Capsule()
                    .fill(theme.signal)
                    .frame(width: 4, height: 4)
                    .opacity(isRunning ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: isRunning)
                    .padding(.top, showLabel ? -3 : -2)
            }
            .rotationEffect(.degrees(model.editing ? wiggle : 0))
        }
        .buttonStyle(PressScaleStyle())
        .contextMenu { menu }
        .accessibilityLabel(model.title(for: item))
    }

    /// Edit mode tilts icons very slightly instead of jiggling them.
    private var wiggle: Double { (Double(abs(item.key.hashValue % 7)) - 3) * 0.4 }

    private func report(_ rect: CGRect) {
        frame = rect
        if !model.editing { model.iconFrames[item.key] = rect }
    }

    @ViewBuilder private var menu: some View {
        Button { openItem(item, frame == .zero ? nil : frame) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
        if case .guest(let path) = item {
            Button {
                Task { try? await model.appModel(for: path)?.runApp(multitask: false) }
            } label: { Label("Open full screen", systemImage: "rectangle.portrait.and.arrow.forward") }
            Button {
                model.libraryFocus = path
                openItem(.system(.library), nil)
            } label: { Label("App info", systemImage: "info.circle") }
        }
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { model.editing = true }
        } label: { Label("Edit Home Screen", systemImage: "square.grid.3x3") }
        if case .guest = item {
            Button(role: .destructive) { model.remove(item) } label: { Label("Remove from Home", systemImage: "minus.circle") }
        }
    }
}

// MARK: - Dots and dock

@available(iOS 16.0, *)
private struct PageDots: View {
    let count: Int
    let progress: CGFloat
    let theme: PTheme
    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<max(count, 1), id: \.self) { i in
                // Width and brightness follow the scroll position continuously, so dots stretch instead of popping.
                let near = max(0, 1 - abs(progress - CGFloat(i)))
                Capsule()
                    .fill(theme.label.opacity(0.4 + 0.6 * near))
                    .frame(width: 6 + 10 * near, height: 6)
            }
        }
        .opacity(count > 1 ? 1 : 0)
        .frame(height: 10)
        .accessibilityHidden(true)
    }
}

@available(iOS 16.0, *)
private struct DockView: View {
    let theme: PTheme
    let openItem: (HomeItem, CGRect?) -> Void
    let darkIcon: Bool
    @EnvironmentObject var model: ShellModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(model.dock, id: \.self) { item in
                HomeIcon(item: item, theme: theme, darkIcon: darkIcon, showLabel: false, openItem: openItem)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .background(theme.surfaceTint, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(PBevel(cornerRadius: 28).opacity(0.6))
        .shadow(color: .black.opacity(0.3), radius: 18, y: 10)
    }
}

// MARK: - Button styles

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct PillButtonStyle: ButtonStyle {
    let fill: Color
    let text: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PFont.geist(14, .semibold))
            .foregroundStyle(text)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(fill, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
