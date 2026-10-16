//
//  PseudoRefreshBridge.swift
//  pseudOS (fork of LiveContainer, see FORK.md)
//
//  Lets pseudOS's Settings app run built-in SideStore's "Refresh All" with progress, the same way the
//  Shortcuts and widget intents do. Reached via NSClassFromString, because this framework is loaded at runtime.
//

import Foundation

@objc(PseudoRefreshBridge)
public final class PseudoRefreshBridge: NSObject {
    private static var observation: NSKeyValueObservation?

    @objc(refreshWithProgress:completion:)
    public static func refresh(progress: @escaping (Double) -> Void, completion: @escaping (NSString?) -> Void) {
        guard #available(iOS 17.0, *) else {
            completion("Refreshing from pseudOS needs iOS 17 or later. Open SideStore to refresh instead.")
            return
        }
        let p = Progress(totalUnitCount: 100)
        observation = p.observe(\.fractionCompleted) { pr, _ in
            let value = pr.fractionCompleted
            DispatchQueue.main.async { progress(value) }
        }
        Task {
            do {
                try await performIntentRefresh(identifier: "RefreshAllIntent", mangledTypeName: "9SideStore20RefreshAllAppsIntentV", intentProgress: p)
                DispatchQueue.main.async { observation = nil; completion(nil) }
            } catch {
                let message = error.localizedDescription as NSString
                DispatchQueue.main.async { observation = nil; completion(message) }
            }
        }
    }
}
