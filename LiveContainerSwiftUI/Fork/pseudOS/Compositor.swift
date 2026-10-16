//
//  Compositor.swift
//  pseudOS
//
//  Owns every app window (guest processes and stock apps) and drives the bottom-edge gesture,
//  the app switcher and the open/close animations. UIKit, so gestures track the finger every frame
//  and every animation is an interruptible spring that inherits the finger's velocity.
//

import UIKit
import SwiftUI
import Combine

// MARK: - Window

@available(iOS 16.0, *)
final class ShellWindow {
    let key: String              // HomeItem.key, or "app:<bundle folder>" for guests
    let title: String
    let container = UIView()
    let content: UIViewController
    let guest: GuestHostController?
    let system: SystemApp?
    let caption = UIStackView()
    var started = false

    init(key: String, title: String, content: UIViewController, guest: GuestHostController?, system: SystemApp?) {
        self.key = key
        self.title = title
        self.content = content
        self.guest = guest
        self.system = system
        container.clipsToBounds = true
        container.layer.cornerCurve = .continuous
        container.backgroundColor = .black
        container.alpha = 0
        container.isUserInteractionEnabled = false
    }

    var dataUUID: String? { guest?.dataUUID }
    var isGuest: Bool { guest != nil }
}

// MARK: - Compositor

@available(iOS 16.0, *)
final class ShellCompositor: UIViewController, UIGestureRecognizerDelegate {
    enum Mode: Equatable { case home, app(String), switcher }

    private let model = ShellModel.shared
    private let prefs = PseudoPrefs.shared
    private weak var sceneDelegate: SceneDelegate?

    private let wallpaperView = UIImageView()
    private var homeHost: UIHostingController<AnyView>!
    private let switcherBackdrop = UIVisualEffectView(effect: nil)
    private let windowsLayer = PassthroughView()
    private let captionsLayer = UIView()
    private let edgeStrip = UIView()
    private let handle = UIView()
    private let toastLabel = PaddedLabel()

    private(set) var mode: Mode = .home
    private var windows: [ShellWindow] = []          // most recent first
    private var pendingLaunchFrames: [String: CGRect] = [:]

    // Switcher state
    private var switcherOffset: CGFloat = 0
    private var switcherOrder: [ShellWindow] = []

    // Edge gesture state
    private var displayLink: CADisplayLink?
    private var lastMoveTime: CFTimeInterval = 0
    private var lastMovePoint: CGPoint = .zero
    private var gestureStart: Mode = .home
    private var armed = false
    private var dragged: ShellWindow?
    private var currentTranslation: CGPoint = .zero

    // Switcher card gesture state
    private var cardPanAxis: Int = 0                  // 0 undecided, 1 horizontal, 2 vertical
    private var cardPanWindow: ShellWindow?
    private var offsetAtPanStart: CGFloat = 0

    private var animators: [UIViewPropertyAnimator] = []
    private let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private let softImpact = UIImpactFeedbackGenerator(style: .soft)

    // Geometry
    private var W: CGFloat { view.bounds.width }
    private var H: CGFloat { view.bounds.height }
    private var screenRadius: CGFloat {
        // Private but long-standing; read defensively so a rename can't crash the shell.
        guard let screen = view.window?.screen, screen.responds(to: NSSelectorFromString("_displayCornerRadius")) else { return 44 }
        return (screen.value(forKey: "_displayCornerRadius") as? CGFloat) ?? 44
    }
    private var cardScale: CGFloat { W > H ? 0.46 : 0.62 }
    private var cardSpacing: CGFloat { W * cardScale + 24 }
    private let cardRadius: CGFloat = 30

    init(sceneDelegate: SceneDelegate?) {
        self.sceneDelegate = sceneDelegate
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Setup

    override func viewDidLoad() {
        super.viewDidLoad()
        PFont.registerIfNeeded()
        PSystemHost.styleNavigationBars()
        view.backgroundColor = .black

        wallpaperView.contentMode = .scaleAspectFill
        wallpaperView.frame = view.bounds
        wallpaperView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(wallpaperView)

        homeHost = UIHostingController(rootView: AnyView(
            HomeView(openItem: { [weak self] item, frame in self?.open(item, from: frame) },
                     openSwitcher: { [weak self] in self?.showSwitcher(from: nil) })
                .environmentObject(model)
                .environmentObject(prefs)
                .environmentObject(UpdateTracker.shared)
        ))
        homeHost.view.backgroundColor = .clear
        addChild(homeHost)
        homeHost.view.frame = view.bounds
        homeHost.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(homeHost.view)
        homeHost.didMove(toParent: self)

        switcherBackdrop.frame = view.bounds
        switcherBackdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        switcherBackdrop.isUserInteractionEnabled = false
        view.addSubview(switcherBackdrop)

        windowsLayer.frame = view.bounds
        windowsLayer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // Only the switcher catches touches on the layer itself; otherwise they go to the window in front or the home screen.
        windowsLayer.capturesTouches = { [weak self] in self?.mode == .switcher }
        view.addSubview(windowsLayer)

        captionsLayer.frame = view.bounds
        captionsLayer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        captionsLayer.isUserInteractionEnabled = false
        captionsLayer.alpha = 0
        view.addSubview(captionsLayer)

        // Switcher gestures live on the windows layer and only run in switcher mode.
        let cardPan = UIPanGestureRecognizer(target: self, action: #selector(handleCardPan(_:)))
        cardPan.delegate = self
        windowsLayer.addGestureRecognizer(cardPan)
        let cardTap = UITapGestureRecognizer(target: self, action: #selector(handleCardTap(_:)))
        windowsLayer.addGestureRecognizer(cardTap)

        // The bottom edge strip and its handle sit above everything.
        edgeStrip.backgroundColor = .clear
        view.addSubview(edgeStrip)
        handle.layer.cornerRadius = 2.5
        handle.isUserInteractionEnabled = false
        edgeStrip.addSubview(handle)
        let edgePan = UIPanGestureRecognizer(target: self, action: #selector(handleEdgePan(_:)))
        edgePan.maximumNumberOfTouches = 1
        edgeStrip.addGestureRecognizer(edgePan)

        toastLabel.alpha = 0
        toastLabel.numberOfLines = 2
        toastLabel.textAlignment = .center
        toastLabel.layer.cornerRadius = 14
        toastLabel.layer.cornerCurve = .continuous
        toastLabel.clipsToBounds = true
        view.addSubview(toastLabel)

        // The Library (upstream's LiveContainer UI) is created up front and kept alive: its app list
        // owns the install pipeline and LiveContainer's startup checks.
        DataManager.shared.model.mainWindowOpened = false
        _ = makeSystemWindow(.library, keepHidden: true)

        model.compositor = self
        model.isMounted = true
        applyAppearance()
        observeModel()

        // Startup work that shouldn't delay the first frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            Task { await UpdateTracker.shared.checkNow() }
            SigningRefresher.refreshIfNeeded()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let stripH: CGFloat = 26
        edgeStrip.frame = CGRect(x: 0, y: H - stripH, width: W, height: stripH)
        handle.frame = CGRect(x: (W - 134) / 2, y: stripH - 13, width: 134, height: 5)
        for w in windows { w.container.bounds = view.bounds; w.content.view.frame = view.bounds }
        if case .switcher = mode { layoutSwitcher(animated: false) }
        else if case .app(let key) = mode, let w = window(key) { w.container.center = CGPoint(x: W / 2, y: H / 2) }
        if wallpaperView.image?.size != view.bounds.size { applyAppearance() }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in self.view.setNeedsLayout(); self.view.layoutIfNeeded() })
    }

    private var cancellables: [AnyCancellable] = []

    private func observeModel() {
        cancellables.append(prefs.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyAppearance() }
        })
        cancellables.append(model.$toast.sink { [weak self] text in
            DispatchQueue.main.async { self?.showToast(text) }
        })
    }

    private func applyAppearance() {
        let theme = PTheme.current(prefs)
        let accent = UIColor(theme.accent)
        let size = view.bounds.size == .zero ? UIScreen.main.bounds.size : view.bounds.size
        wallpaperView.image = PWallpaper.image(seed: prefs.wallpaperSeed, size: size, dark: theme.dark, accent: accent)
        overrideUserInterfaceStyle = theme.dark ? .dark : .light
        toastLabel.backgroundColor = UIColor(theme.surfaceSolid)
        toastLabel.textColor = UIColor(theme.label)
        toastLabel.font = PFont.uiGeist(13.5, .medium)
        updateHandleColor()
    }

    private func updateHandleColor() {
        let inApp: Bool = { if case .app = mode { return true }; return false }()
        let theme = PTheme.current(prefs)
        handle.backgroundColor = armed ? UIColor(theme.accent)
            : (inApp ? UIColor.white.withAlphaComponent(0.75) : UIColor(theme.label).withAlphaComponent(0.7))
        handle.layer.shadowColor = UIColor.black.cgColor
        handle.layer.shadowOpacity = inApp ? 0.35 : 0
        handle.layer.shadowRadius = 2
        handle.layer.shadowOffset = .zero
    }

    // MARK: Windows

    private func window(_ key: String) -> ShellWindow? { windows.first { $0.key == key } }

    private func add(_ w: ShellWindow) {
        addChild(w.content)
        w.container.frame = view.bounds
        w.content.view.frame = w.container.bounds
        w.content.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        w.container.addSubview(w.content.view)
        windowsLayer.addSubview(w.container)
        w.content.didMove(toParent: self)
        buildCaption(for: w)
        windows.append(w)
    }

    private func buildCaption(for w: ShellWindow) {
        let theme = PTheme.current(prefs)
        w.caption.axis = .horizontal
        w.caption.spacing = 8
        w.caption.alignment = .center
        let icon: UIView
        if let s = w.system {
            let renderer = ImageRenderer(content: PTile(size: 24) { PGlyph(kind: s.glyph, size: 12, accent: theme.accent) }.shadow(radius: 0))
            renderer.scale = UIScreen.main.scale
            let iv = UIImageView(image: renderer.uiImage)
            iv.layer.cornerRadius = 6; iv.layer.cornerCurve = .continuous; iv.clipsToBounds = true
            icon = iv
        } else if let path = w.key.hasPrefix("app:") ? String(w.key.dropFirst(4)) : nil,
                  let img = model.appModel(for: path)?.appInfo.iconIsDarkIcon(false) {
            let iv = UIImageView(image: img)
            iv.layer.cornerRadius = 6; iv.layer.cornerCurve = .continuous; iv.clipsToBounds = true
            icon = iv
        } else {
            icon = UIView()
        }
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let label = UILabel()
        label.text = w.title
        label.font = PFont.uiGeist(13.5, .medium)
        label.textColor = UIColor(theme.label)
        w.caption.addArrangedSubview(icon)
        w.caption.addArrangedSubview(label)
        w.caption.alpha = 0
        captionsLayer.addSubview(w.caption)
    }

    private func remove(_ w: ShellWindow) {
        if w.system == .library {
            // The Library stays alive (see viewDidLoad); quitting just hides it.
            hide(w)
            model.running.removeAll { $0 == w.key }
            return
        }
        w.content.willMove(toParent: nil)
        w.container.removeFromSuperview()
        w.content.removeFromParent()
        w.caption.removeFromSuperview()
        windows.removeAll { $0 === w }
        model.running.removeAll { $0 == w.key }
    }

    private func hide(_ w: ShellWindow) {
        w.container.alpha = 0
        w.container.isUserInteractionEnabled = false
        w.container.transform = .identity
        w.container.center = CGPoint(x: W / 2, y: H / 2)
        w.container.layer.cornerRadius = 0
        w.caption.alpha = 0
    }

    private func touch(_ w: ShellWindow) {
        model.running.removeAll { $0 == w.key }
        model.running.insert(w.key, at: 0)
    }

    private var runningWindows: [ShellWindow] {
        model.running.compactMap { key in window(key) }
    }

    /// Keeps the number of running guest processes at the user's limit by quitting the least recently used.
    private func enforceLimit(adding key: String) {
        let guests = runningWindows.filter { $0.isGuest && $0.key != key }
        let limit = max(1, prefs.runningLimit)
        guard guests.count >= limit else { return }
        for victim in guests.suffix(guests.count - limit + 1) {
            model.showToast("Closed \(victim.title) to stay at \(limit) running apps")
            victim.guest?.terminate()
            remove(victim)
        }
    }

    // MARK: Opening apps

    /// Called by the home screen. Stock apps open directly; guests go through upstream's runApp,
    /// which signs the app and calls back into launchGuest (via the FORK hook in LCUtils).
    func open(_ item: HomeItem, from iconFrame: CGRect?) {
        if case .switcher = mode { return }
        switch item {
        case .system(let s):
            let w = window(item.key) ?? makeSystemWindow(s, keepHidden: false)
            present(w, from: iconFrame)
        case .guest(let path):
            if let w = window(item.key), w.started {
                present(w, from: iconFrame)
                return
            }
            guard let app = model.appModel(for: path), !model.launching.contains(item.key) else { return }
            if let iconFrame { pendingLaunchFrames[item.key] = iconFrame }
            model.launching.insert(item.key)
            Task { @MainActor [self] in
                do {
                    if app.appInfo.isLocked {
                        guard try await LCUtils.authenticateUser() else { self.model.launching.remove(item.key); return }
                    }
                    try await app.runApp(multitask: true)
                } catch {
                    self.model.showToast("Couldn't open \(app.displayName): \(error.localizedDescription)")
                }
                self.model.launching.remove(item.key)
            }
        }
    }

    @discardableResult
    private func makeSystemWindow(_ s: SystemApp, keepHidden: Bool) -> ShellWindow {
        let root: AnyView
        if s == .library {
            var tab = AnyView(LCTabView()
                .environmentObject(DataManager.shared.model)
                .environmentObject(LCAppSortManager.shared))
            if let sceneDelegate { tab = AnyView(tab.environmentObject(sceneDelegate)) }
            root = tab
        } else {
            root = AnyView(SystemAppView(app: s)
                .environmentObject(model)
                .environmentObject(prefs)
                .environmentObject(UpdateTracker.shared))
        }
        let host: UIHostingController<AnyView> = s == .library ? UIHostingController(rootView: root) : PSystemHost(rootView: root)
        let w = ShellWindow(key: HomeItem.system(s).key, title: s.name, content: host, guest: nil, system: s)
        w.started = true
        add(w)
        return w
    }

    /// FORK hook target: start a guest process in a new full-screen window.
    func launchGuest(displayName: String, bundleId: String, dataUUID: String, completion: ((NSNumber?, Error?) -> Void)?) {
        let key = "app:" + bundleId
        if let existing = window(key), existing.started {
            present(existing, from: pendingLaunchFrames.removeValue(forKey: key))
            completion?(NSNumber(value: existing.guest?.appScene?.pid ?? 0), nil)
            return
        }
        enforceLimit(adding: key)
        let host = GuestHostController(bundleId: bundleId, dataUUID: dataUUID)
        let w = ShellWindow(key: key, title: displayName, content: host, guest: host, system: nil)
        add(w)
        host.onStart = { [weak self] pid, error in
            completion?(pid, error)
            if error != nil, let self { self.model.launching.remove(key) }
        }
        host.onExit = { [weak self, weak w] in
            guard let self, let w else { return }
            self.guestDidExit(w)
        }
        host.start()
        w.started = true
        present(w, from: pendingLaunchFrames.removeValue(forKey: key))
    }

    func bringGuestToFront(dataUUID: String, urlScheme: String?) -> Bool {
        guard let w = windows.first(where: { $0.dataUUID == dataUUID }) else { return false }
        if let urlScheme { w.guest?.open(urlScheme: urlScheme) }
        if case .switcher = mode { openFromSwitcher(w); return true }
        present(w, from: model.iconFrames[w.key])
        return true
    }

    /// Quits a running app (used before updating it).
    func quit(key: String) {
        guard let w = window(key) else { return }
        if mode == .app(key) { goHome(velocity: .zero) }
        if let g = w.guest { g.onExit = nil; g.terminate() }
        switcherOrder.removeAll { $0 === w }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { self.remove(w) }
    }

    private func guestDidExit(_ w: ShellWindow) {
        let wasForeground = mode == .app(w.key)
        let wasCard = mode == .switcher && switcherOrder.contains { $0 === w }
        model.launching.remove(w.key)
        if wasForeground {
            model.showToast("\(w.title) quit")
            goHome(velocity: .zero)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { self.remove(w) }
        } else {
            remove(w)
            if wasCard {
                switcherOrder.removeAll { $0 === w }
                if switcherOrder.isEmpty { dismissSwitcher() } else { layoutSwitcher(animated: true) }
            }
        }
    }

    /// Brings a window to the front, growing it out of its icon when there is one.
    private func present(_ w: ShellWindow, from iconFrame: CGRect?) {
        stopAnimations()
        let previous: ShellWindow? = { if case .app(let k) = mode { return window(k) }; return nil }()
        touch(w)
        mode = .app(w.key)
        model.foreground = w.key
        windowsLayer.bringSubviewToFront(w.container)
        w.container.isUserInteractionEnabled = true
        setStatusBarTarget(w)

        if let iconFrame, !UIAccessibility.isReduceMotionEnabled {
            place(w, frame: iconFrame, radius: iconFrame.width * 0.25)
            w.container.alpha = 0.3
        } else {
            place(w, frame: view.bounds.insetBy(dx: W * 0.04, dy: H * 0.04), radius: screenRadius)
            w.container.alpha = 0
        }
        animate(response: 0.48, damping: 0.86, velocity: .zero) {
            self.place(w, frame: self.view.bounds, radius: self.screenRadius)
            w.container.alpha = 1
            self.homeHost.view.alpha = 0
            self.homeHost.view.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
            if let previous, previous !== w { previous.container.alpha = 0 }
        } completion: {
            w.container.layer.cornerRadius = 0
            if let previous, previous !== w { self.hide(previous) }
        }
        updateHandleColor()
    }

    private func setStatusBarTarget(_ w: ShellWindow?) {
        let manager = view.window?.windowScene?.statusBarManager as? LCStatusBarManager
        manager?.nativeWindowViewController = w?.guest?.appScene
    }

    // MARK: Going home

    private func goHome(velocity: CGPoint) {
        stopAnimations()
        guard case .app(let key) = mode, let w = window(key) else {
            mode = .home; model.foreground = nil; showHome(); return
        }
        mode = .home
        model.foreground = nil
        w.container.isUserInteractionEnabled = false
        setStatusBarTarget(nil)
        let target = model.iconFrames[w.key]
        let v = normalizedVelocity(velocity, distance: max(1, H * 0.4))
        animate(response: 0.42, damping: 0.88, velocity: v) {
            if let target {
                self.place(w, frame: target, radius: target.width * 0.25)
                w.container.alpha = 0
            } else {
                self.place(w, frame: self.view.bounds.insetBy(dx: self.W * 0.3, dy: self.H * 0.3), radius: 30)
                w.container.alpha = 0
            }
            self.homeHost.view.alpha = 1
            self.homeHost.view.transform = .identity
        } completion: {
            if self.mode == .home { self.hide(w) }
        }
        updateHandleColor()
    }

    private func showHome() {
        animate(response: 0.4, damping: 0.9, velocity: .zero) {
            self.homeHost.view.alpha = 1
            self.homeHost.view.transform = .identity
        }
        updateHandleColor()
    }

    // MARK: Geometry helpers

    /// Positions a window so it visually fills `frame` (non-uniform scale for icon-sized frames).
    private func place(_ w: ShellWindow, frame: CGRect, radius: CGFloat) {
        let sx = frame.width / max(W, 1), sy = frame.height / max(H, 1)
        w.container.bounds = view.bounds
        w.container.center = CGPoint(x: frame.midX, y: frame.midY)
        w.container.transform = CGAffineTransform(scaleX: sx, y: sy)
        w.container.layer.cornerRadius = radius / max(min(sx, sy), 0.01)
    }

    private func cardFrame(index: Int, offset: CGFloat) -> CGRect {
        let cw = W * cardScale, ch = H * cardScale
        let cx = W / 2 - CGFloat(index) * cardSpacing + offset
        let cy = H * 0.48
        return CGRect(x: cx - cw / 2, y: cy - ch / 2, width: cw, height: ch)
    }

    private func normalizedVelocity(_ v: CGPoint, distance: CGFloat) -> CGVector {
        CGVector(dx: v.x / distance, dy: v.y / distance)
    }

    private func animate(response: Double, damping: CGFloat, velocity: CGVector,
                         _ changes: @escaping () -> Void, completion: (() -> Void)? = nil) {
        if UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.2, animations: changes) { _ in completion?() }
            return
        }
        let params = UISpringTimingParameters(dampingRatio: damping, initialVelocity: velocity)
        let animator = UIViewPropertyAnimator(duration: response * 1.2, timingParameters: params)
        animator.isInterruptible = true
        animator.addAnimations(changes)
        animator.addCompletion { [weak self, weak animator] pos in
            if let self, let animator { self.animators.removeAll { $0 === animator } }
            if pos == .end { completion?() }
        }
        animators.append(animator)
        animator.startAnimation()
    }

    /// Freezes running animations where they are, so a new gesture picks up from what's on screen.
    private func stopAnimations() {
        for a in animators where a.state == .active {
            a.pauseAnimation()
            a.stopAnimation(false)
            a.finishAnimation(at: .current)
        }
        animators.removeAll()
    }

    // MARK: Bottom-edge gesture

    @objc private func handleEdgePan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: view)
        switch g.state {
        case .began:
            stopAnimations()
            gestureStart = mode
            armed = false
            currentTranslation = t
            lastMovePoint = g.location(in: view)
            lastMoveTime = CACurrentMediaTime()
            lightImpact.prepare(); softImpact.prepare()
            if case .app(let key) = mode { dragged = window(key) } else { dragged = nil }
            startDisplayLink()
        case .changed:
            currentTranslation = t
            let p = g.location(in: view)
            if hypot(p.x - lastMovePoint.x, p.y - lastMovePoint.y) > 2.5 {
                lastMovePoint = p
                lastMoveTime = CACurrentMediaTime()
            }
            trackDrag(translation: t)
        case .ended, .cancelled, .failed:
            stopDisplayLink()
            finishEdgePan(translation: t, velocity: g.velocity(in: view), cancelled: g.state != .ended)
        default: break
        }
    }

    private func startDisplayLink() {
        stopDisplayLink()
        let link = CADisplayLink(target: self, selector: #selector(displayTick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() { displayLink?.invalidate(); displayLink = nil }

    /// Runs every frame while the finger is down: a resting finger after an upward swipe arms the switcher.
    @objc private func displayTick() {
        let lift = -currentTranslation.y
        let resting = CACurrentMediaTime() - lastMoveTime > 0.08
        if !armed, resting, lift > 34, gestureStart != .switcher, !windowsForSwitcher().isEmpty {
            arm()
        } else if armed, lift < 22 {
            disarm()
        }
    }

    private func windowsForSwitcher() -> [ShellWindow] { runningWindows }

    private func trackDrag(translation t: CGPoint) {
        let lift = max(0, -t.y)
        if let w = dragged, gestureStart != .switcher {
            // The app shrinks under the finger and follows it sideways.
            let s = max(0.42, 1 - lift / (H * 1.15))
            let cw = W * s, ch = H * s
            let cx = W / 2 + t.x * 0.55
            let cy = H - ch / 2 - lift * 0.62 - (1 - s) * 40
            let radius = screenRadius + (cardRadius - screenRadius) * min(1, lift / 140)
            place(w, frame: CGRect(x: cx - cw / 2, y: cy - ch / 2, width: cw, height: ch), radius: radius)
            let homeAmount = armed ? 0 : min(1, lift / 260)
            homeHost.view.alpha = homeAmount
            let hs = 0.94 + 0.06 * homeAmount
            homeHost.view.transform = CGAffineTransform(scaleX: hs, y: hs)
            if armed { layoutSwitcherAroundDragged(w) }
        } else if gestureStart == .home, armed {
            layoutSwitcher(animated: false, liftOverride: lift)
        }
    }

    private func arm() {
        armed = true
        lightImpact.impactOccurred()
        updateHandleColor()
        if let w = dragged {
            switcherOrder = windowsForSwitcher()
            if let i = switcherOrder.firstIndex(where: { $0 === w }), i != 0 {
                switcherOrder.remove(at: i); switcherOrder.insert(w, at: 0)
            }
            prepareCards(except: w)
            animate(response: 0.32, damping: 0.9, velocity: .zero) {
                self.switcherBackdrop.effect = UIBlurEffect(style: .systemMaterialDark)
                self.homeHost.view.alpha = 0.6
                self.layoutSwitcherAroundDragged(w)
                for c in self.switcherOrder where c !== w { c.container.alpha = 1 }
            }
        } else {
            // From home: the most recent apps rise in from the bottom edge.
            switcherOrder = windowsForSwitcher()
            switcherOffset = 0
            prepareCards(except: nil)
            for (i, c) in switcherOrder.enumerated() {
                let f = cardFrame(index: i, offset: 0)
                place(c, frame: f.offsetBy(dx: 0, dy: H * 0.5), radius: cardRadius)
                c.container.alpha = 1
            }
            mode = .switcher
            animate(response: 0.4, damping: 0.86, velocity: .zero) {
                self.switcherBackdrop.effect = UIBlurEffect(style: .systemMaterialDark)
                self.homeHost.view.alpha = 0.6
                self.layoutSwitcher(animated: false)
            }
        }
    }

    private func disarm() {
        armed = false
        updateHandleColor()
        guard let w = dragged else {
            // Swiped back down from home: put the cards away again.
            if mode == .switcher { dismissSwitcher() }
            return
        }
        animate(response: 0.3, damping: 0.9, velocity: .zero) {
            self.switcherBackdrop.effect = nil
            self.captionsLayer.alpha = 0
            for c in self.switcherOrder where c !== w { c.container.alpha = 0 }
        } completion: {
            for c in self.switcherOrder where c !== w && self.mode != .switcher { self.hide(c) }
        }
    }

    private func prepareCards(except dragged: ShellWindow?) {
        for c in switcherOrder where c !== dragged {
            c.container.isUserInteractionEnabled = false
            if c.container.alpha == 0 {
                // Start just off the dragged card's left edge, so cards slide in rather than pop.
                place(c, frame: cardFrame(index: 1, offset: 0).offsetBy(dx: -W * 0.3, dy: 0), radius: cardRadius)
            }
        }
        // Older apps sit behind newer ones.
        for c in switcherOrder.reversed() { windowsLayer.bringSubviewToFront(c.container) }
        if let dragged { windowsLayer.bringSubviewToFront(dragged.container) }
    }

    /// While the finger holds the current app, the other cards line up relative to it.
    private func layoutSwitcherAroundDragged(_ w: ShellWindow) {
        let f = w.container.frame
        let s = f.width / W
        let spacing = W * s + 24 * s / cardScale
        for (i, c) in switcherOrder.enumerated() where c !== w {
            let cf = CGRect(x: f.minX - CGFloat(i) * spacing, y: f.minY, width: f.width, height: f.height)
            place(c, frame: cf, radius: cardRadius)
        }
        captionsLayer.alpha = 0
    }

    private func finishEdgePan(translation t: CGPoint, velocity v: CGPoint, cancelled: Bool) {
        let lift = -t.y
        defer { armed = false; dragged = nil; updateHandleColor() }
        switch gestureStart {
        case .app:
            guard let w = dragged else { return }
            if armed && v.y > -1100 && !cancelled {
                settleIntoSwitcher(focus: w, velocity: v)
            } else if !cancelled && (v.y < -350 || lift > 150) {
                if armed { collapseCardsToHome(except: w) }
                goHome(velocity: v)
            } else {
                // Back into the app.
                if armed { collapseCardsToHome(except: w) }
                animate(response: 0.38, damping: 0.86, velocity: normalizedVelocity(v, distance: H)) {
                    self.place(w, frame: self.view.bounds, radius: self.screenRadius)
                    self.homeHost.view.alpha = 0
                    self.homeHost.view.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
                    self.switcherBackdrop.effect = nil
                } completion: { w.container.layer.cornerRadius = 0 }
                mode = .app(w.key)
            }
        case .home:
            if mode == .switcher && !cancelled { settleIntoSwitcher(focus: nil, velocity: v) }
            else if mode == .switcher { dismissSwitcher() }
        case .switcher:
            if !cancelled && (v.y < -250 || lift > 60) { dismissSwitcher() }
        }
    }

    private func collapseCardsToHome(except w: ShellWindow) {
        for c in switcherOrder where c !== w {
            UIView.animate(withDuration: 0.2) { c.container.alpha = 0 } completion: { _ in
                if self.mode != .switcher { self.hide(c) }
            }
        }
        captionsLayer.alpha = 0
    }

    // MARK: Switcher

    func showSwitcher(from _: CGRect?) {
        guard !windowsForSwitcher().isEmpty else { model.showToast("No apps running"); return }
        stopAnimations()
        gestureStart = .home
        dragged = nil
        arm()
        settleIntoSwitcher(focus: nil, velocity: .zero)
        armed = false
        updateHandleColor()
    }

    private func settleIntoSwitcher(focus: ShellWindow?, velocity: CGPoint) {
        if switcherOrder.isEmpty { switcherOrder = windowsForSwitcher() }
        mode = .switcher
        model.foreground = nil
        setStatusBarTarget(nil)
        switcherOffset = 0
        for c in switcherOrder { c.container.isUserInteractionEnabled = false; c.container.alpha = 1 }
        animate(response: 0.42, damping: 0.84, velocity: normalizedVelocity(velocity, distance: H)) {
            self.switcherBackdrop.effect = UIBlurEffect(style: .systemMaterialDark)
            self.homeHost.view.alpha = 0.6
            self.homeHost.view.transform = .identity
            self.layoutSwitcher(animated: false)
            self.captionsLayer.alpha = 1
        }
    }

    private func layoutSwitcher(animated: Bool, liftOverride: CGFloat? = nil) {
        let changes = {
            for (i, c) in self.switcherOrder.enumerated() {
                var f = self.cardFrame(index: i, offset: self.switcherOffset)
                if let lift = liftOverride { f = f.offsetBy(dx: 0, dy: max(0, self.H * 0.5 - lift * 1.6)) }
                self.place(c, frame: f, radius: self.cardRadius)
                c.container.alpha = 1
                let size = c.caption.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
                c.caption.frame = CGRect(x: f.minX + 2, y: f.minY - size.height - 10, width: max(size.width, 40), height: size.height)
                c.caption.alpha = 1
            }
        }
        if animated { animate(response: 0.4, damping: 0.86, velocity: .zero, changes) } else { changes() }
    }

    private func dismissSwitcher() {
        stopAnimations()
        let cards = switcherOrder
        mode = .home
        model.foreground = nil
        animate(response: 0.4, damping: 0.9, velocity: .zero) {
            for (i, c) in cards.enumerated() {
                if let target = self.model.iconFrames[c.key] {
                    self.place(c, frame: target, radius: target.width * 0.25)
                } else {
                    self.place(c, frame: self.cardFrame(index: i, offset: self.switcherOffset).offsetBy(dx: 0, dy: self.H * 0.6), radius: self.cardRadius)
                }
                c.container.alpha = 0
            }
            self.switcherBackdrop.effect = nil
            self.captionsLayer.alpha = 0
            self.homeHost.view.alpha = 1
            self.homeHost.view.transform = .identity
        } completion: {
            if self.mode == .home { cards.forEach(self.hide) }
        }
        switcherOrder = []
        updateHandleColor()
    }

    private func openFromSwitcher(_ w: ShellWindow) {
        stopAnimations()
        let others = switcherOrder.filter { $0 !== w }
        switcherOrder = []
        touch(w)
        mode = .app(w.key)
        model.foreground = w.key
        windowsLayer.bringSubviewToFront(w.container)
        w.container.isUserInteractionEnabled = true
        setStatusBarTarget(w)
        animate(response: 0.44, damping: 0.88, velocity: .zero) {
            self.place(w, frame: self.view.bounds, radius: self.screenRadius)
            for o in others { o.container.alpha = 0 }
            self.switcherBackdrop.effect = nil
            self.captionsLayer.alpha = 0
            self.homeHost.view.alpha = 0
            self.homeHost.view.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
        } completion: {
            w.container.layer.cornerRadius = 0
            others.forEach(self.hide)
        }
        updateHandleColor()
    }

    private func quit(_ w: ShellWindow) {
        switcherOrder.removeAll { $0 === w }
        if let g = w.guest { g.onExit = nil; g.terminate() }
        remove(w)
        if switcherOrder.isEmpty { dismissSwitcher() } else {
            switcherOffset = min(switcherOffset, CGFloat(switcherOrder.count - 1) * cardSpacing)
            layoutSwitcher(animated: true)
        }
    }

    @objc private func handleCardTap(_ g: UITapGestureRecognizer) {
        guard mode == .switcher else { return }
        let p = g.location(in: windowsLayer)
        if let w = switcherOrder.first(where: { $0.container.frame.contains(p) }) {
            openFromSwitcher(w)
        } else {
            dismissSwitcher()
        }
    }

    @objc private func handleCardPan(_ g: UIPanGestureRecognizer) {
        guard mode == .switcher else { return }
        let t = g.translation(in: windowsLayer)
        switch g.state {
        case .began:
            stopAnimations()
            let v = g.velocity(in: windowsLayer)
            cardPanAxis = abs(v.x) > abs(v.y) ? 1 : 2
            offsetAtPanStart = switcherOffset
            let p = g.location(in: windowsLayer)
            cardPanWindow = cardPanAxis == 2 ? switcherOrder.first { $0.container.frame.contains(p) } : nil
            if cardPanAxis == 2 && cardPanWindow == nil { cardPanAxis = 1 }
        case .changed:
            if cardPanAxis == 1 {
                let maxOffset = CGFloat(max(0, switcherOrder.count - 1)) * cardSpacing
                switcherOffset = rubberBand(offsetAtPanStart + t.x, min: 0, max: maxOffset)
                layoutSwitcher(animated: false)
            } else if let w = cardPanWindow, let i = switcherOrder.firstIndex(where: { $0 === w }) {
                let f = cardFrame(index: i, offset: switcherOffset)
                let dy = t.y < 0 ? t.y : t.y * 0.2
                place(w, frame: f.offsetBy(dx: 0, dy: dy), radius: cardRadius)
                w.container.alpha = max(0.2, 1 + dy / 600)
                w.caption.alpha = max(0, 1 + dy / 120)
            }
        case .ended, .cancelled:
            let v = g.velocity(in: windowsLayer)
            if cardPanAxis == 1 {
                let maxOffset = CGFloat(max(0, switcherOrder.count - 1)) * cardSpacing
                let projected = switcherOffset + v.x * 0.18
                let target = min(max(0, (projected / cardSpacing).rounded() * cardSpacing), maxOffset)
                switcherOffset = target
                animate(response: 0.45, damping: 0.88, velocity: CGVector(dx: v.x / 500, dy: 0)) { self.layoutSwitcher(animated: false) }
            } else if let w = cardPanWindow {
                if t.y < -110 || v.y < -700 {
                    lightImpact.impactOccurred()
                    let f = w.container.frame
                    UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseIn]) {
                        self.place(w, frame: f.offsetBy(dx: 0, dy: -self.H), radius: self.cardRadius)
                        w.container.alpha = 0
                        w.caption.alpha = 0
                    } completion: { _ in self.quit(w) }
                } else {
                    layoutSwitcher(animated: true)
                }
            }
            cardPanWindow = nil
            cardPanAxis = 0
        default: break
        }
    }

    private func rubberBand(_ x: CGFloat, min lo: CGFloat, max hi: CGFloat) -> CGFloat {
        if x < lo { return lo - (lo - x) * 0.35 }
        if x > hi { return hi + (x - hi) * 0.35 }
        return x
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { false }

    // MARK: Toast

    private func showToast(_ text: String?) {
        if let text {
            toastLabel.text = text
            let maxW = min(W - 48, 340)
            let size = toastLabel.sizeThatFits(CGSize(width: maxW, height: 100))
            let top = view.safeAreaInsets.top + 8
            toastLabel.frame = CGRect(x: (W - size.width) / 2, y: top, width: size.width, height: size.height)
            view.bringSubviewToFront(toastLabel)
            toastLabel.transform = CGAffineTransform(translationX: 0, y: -12)
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
                self.toastLabel.alpha = 1
                self.toastLabel.transform = .identity
            }
        } else {
            UIView.animate(withDuration: 0.25) { self.toastLabel.alpha = 0 }
        }
    }

    // MARK: URLs (upstream's LCTabView.dispatchURL, routed into the Library)

    func handle(url: URL) {
        let shared = DataManager.shared.model
        if url.host?.lowercased() == "pseudos-classic" {
            DataManager.shared.model.mainWindowOpened = false
            PseudoPrefs.shared.classicUI = true
            return
        }
        var tab: LCTabIdentifier?
        if url.isFileURL || url.scheme?.lowercased() == "sidestore" { tab = .apps }
        else {
            switch url.host?.lowercased() ?? "" {
            case "livecontainer-launch", "install", "open-web-page", "open-url": tab = .apps
            case "certificate": tab = .settings
            case "source": tab = .sources
            default: tab = nil
            }
        }
        guard let tab else { return }
        shared.selectedTab = tab
        shared.deepLink = url
        // A launch link starts the app itself (it lands back here via the FORK hooks); everything else
        // needs the Library on screen.
        if url.host?.lowercased() != "livecontainer-launch" { open(.system(.library), from: nil) }
    }
}

/// A layer that lets touches through to what's underneath unless `capturesTouches` says otherwise.
final class PassthroughView: UIView {
    var capturesTouches: () -> Bool = { false }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit === self && !capturesTouches() { return nil }
        return hit
    }
}

/// UILabel with padding, for the toast.
final class PaddedLabel: UILabel {
    var insets = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let s = super.sizeThatFits(CGSize(width: size.width - insets.left - insets.right, height: size.height))
        return CGSize(width: s.width + insets.left + insets.right, height: s.height + insets.top + insets.bottom)
    }
}

// MARK: - SwiftUI entry

@available(iOS 16.0, *)
struct PseudoShellView: View {
    @EnvironmentObject var sceneDelegate: SceneDelegate
    @ObservedObject var prefs = PseudoPrefs.shared

    var body: some View {
        CompositorRepresentable(sceneDelegate: sceneDelegate)
            .ignoresSafeArea()
            .preferredColorScheme(prefs.appearance == .dark ? .dark : .light)
            .persistentSystemOverlays(.hidden)
            .defersSystemGestures(on: .bottom)
            .onOpenURL { url in ShellModel.shared.compositor?.handle(url: url) }
    }
}

@available(iOS 16.0, *)
struct CompositorRepresentable: UIViewControllerRepresentable {
    let sceneDelegate: SceneDelegate?
    func makeUIViewController(context: Context) -> ShellCompositor { ShellCompositor(sceneDelegate: sceneDelegate) }
    func updateUIViewController(_ vc: ShellCompositor, context: Context) {}
}
