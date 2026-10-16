//
//  GuestHost.swift
//  pseudOS
//
//  Hosts one guest app full screen. Follows upstream's native-window host (MultitaskSupport/MultitaskAppWindow.swift),
//  so the guest gets the whole screen's settings, safe area and rotation.
//

import UIKit

@available(iOS 16.0, *)
final class GuestHostController: UIViewController, AppSceneViewControllerDelegate {
    let bundleId: String
    let dataUUID: String
    private(set) var appScene: AppSceneViewController?

    /// Called once with the process ID, or an error if the app couldn't start.
    var onStart: ((NSNumber?, Error?) -> Void)?
    /// Called when the guest process exits (quit, crash or terminate).
    var onExit: (() -> Void)?

    init(bundleId: String, dataUUID: String) {
        self.bundleId = bundleId
        self.dataUUID = dataUUID
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        view = UIView()
        view.backgroundColor = .black
    }

    /// Starts the guest. The host's view must already be in the window, because AppSceneViewController
    /// registers for the window scene's settings changes once the process is up.
    func start() {
        guard appScene == nil else { return }
        guard let vc = AppSceneViewController(bundleId: bundleId, dataUUID: dataUUID, delegate: self) else { return }
        appScene = vc
        addChild(vc)
        vc.view.frame = view.bounds
        vc.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(vc.view)
        vc.didMove(toParent: self)
    }

    func terminate() { appScene?.terminate() }

    func open(urlScheme: String) { appScene?.openURLScheme(urlScheme) }

    // MARK: AppSceneViewControllerDelegate

    func appSceneVCAppDidExit(_ vc: AppSceneViewController!) {
        DispatchQueue.main.async { self.onExit?() }
    }

    func appSceneVC(_ vc: AppSceneViewController!, didInitializeWithError error: (any Error)!) {
        DispatchQueue.main.async {
            if let error {
                self.onStart?(nil, error)
                self.onStart = nil
                self.onExit?()
            } else {
                self.onStart?(NSNumber(value: vc.pid), nil)
                self.onStart = nil
            }
        }
    }

    func appSceneVCWillActivateScene(_ vc: AppSceneViewController!) {
        vc.updateSettings { settings in
            guard let settings else { return }
            let insets = vc.view.window?.safeAreaInsets ?? .zero
            settings.peripheryInsets = insets
            settings.safeAreaInsetsPortrait = insets
            settings.deviceOrientation = UIDevice.current.orientation
            let orientation = vc.view.window?.windowScene?.interfaceOrientation ?? .portrait
            settings.setInterfaceOrientation(orientation)
            let size = vc.view.window?.bounds.size ?? vc.view.bounds.size
            if orientation.isLandscape {
                settings.setFrame(CGRect(x: 0, y: 0, width: size.height, height: size.width))
            } else {
                settings.setFrame(CGRect(x: 0, y: 0, width: size.width, height: size.height))
            }
        }
        // Full-screen guests resize with the window (rotation) instead of upstream's debounced frame pushes.
        vc.contentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    func appSceneVC(_ vc: AppSceneViewController!, didUpdateFrom settings: UIMutableApplicationSceneSettings!, transitionContext context: Any!, lifecycleActionType actionType: UInt32) {
        settings.interruptionPolicy = 0
        vc.presenter.scene.updateSettings(settings, withTransitionContext: context, completion: nil)
        // actionType 2 is only sent when the scene enters the foreground: pass any pending URL then.
        if actionType == 2, let url = UserDefaults.standard.string(forKey: "launchAppUrlScheme") {
            UserDefaults.standard.removeObject(forKey: "launchAppUrlScheme")
            vc.openURLScheme(url)
        }
    }

    // PiPManager casts its delegate to DecoratedAppSceneViewController and calls these. pseudOS doesn't
    // offer PiP from its own UI yet, but answering them keeps a stray call from crashing.
    @objc func minimizeWindowPiP() {}
    @objc func unminimizeWindowPiP() {}
    @objc func updateVerticalConstraints() {}
}
