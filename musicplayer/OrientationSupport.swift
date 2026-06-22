import SwiftUI

// MARK: - App-wide orientation control
//
// SwiftUI has no native way to force/restrict interface orientation, so we host
// a tiny UIApplicationDelegate. `supportedInterfaceOrientationsFor` is the one
// authoritative hook UIKit consults, and it reads a mutable lock the app flips
// when entering/leaving fullscreen video.
//
// Default is portrait: every screen is designed portrait, so the app stays
// upright until fullscreen video explicitly asks for landscape.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.orientationLock
    }
}

enum OrientationLock {
    /// Allow landscape and rotate into it (fullscreen video).
    static func enterLandscape() {
        AppDelegate.orientationLock = .landscape
        apply(.landscapeRight)
    }

    /// Restore the portrait-only app shell.
    static func enterPortrait() {
        AppDelegate.orientationLock = .portrait
        apply(.portrait)
    }

    private static func apply(_ orientations: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations))
        // Force the presented controllers to re-query supportedInterfaceOrientations.
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}
