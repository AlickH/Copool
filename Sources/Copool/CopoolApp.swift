import SwiftUI
import CloudKit
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

@main
struct CopoolApp: App {
    private let container: AppContainer
    @StateObject private var trayModel: TrayMenuModel
    #if os(macOS)
    @NSApplicationDelegateAdaptor(CopoolAppDelegate.self) private var appDelegate
    #elseif os(iOS)
    @UIApplicationDelegateAdaptor(CopoolAppDelegate.self) private var appDelegate
    #endif

    init() {
        let container = AppContainer.liveOrCrash()
        self.container = container
        _trayModel = StateObject(wrappedValue: container.trayModel)
        Task { @MainActor in
            container.trayModel.startBackgroundRefresh()
            await container.proxyControlBridge.start()
        }
    }

    var body: some Scene {
        #if os(macOS)
        MenuBarExtra {
            RootScene(container: container, trayModel: trayModel)
                .frame(
                    minWidth: LayoutRules.minimumPanelWidth,
                    idealWidth: LayoutRules.defaultPanelWidth,
                    maxWidth: LayoutRules.maximumPanelWidth,
                    minHeight: LayoutRules.minimumPanelHeight,
                    idealHeight: LayoutRules.defaultPanelHeight
                )
        } label: {
            menuBarIcon
        }
        .menuBarExtraStyle(.window)
        #else
        WindowGroup {
            RootScene(container: container, trayModel: trayModel)
        }
        #endif
    }

    #if os(macOS)
    private var menuBarIcon: Image {
        #if canImport(AppKit)
        if let icon = makeMenuBarSymbolImage() {
            return Image(nsImage: icon)
        }
        #endif
        return Image(systemName: "figure.pool.swim")
    }

    #if canImport(AppKit)
    private func makeMenuBarSymbolImage() -> NSImage? {
        guard let base = NSImage(systemSymbolName: "figure.pool.swim", accessibilityDescription: "Copool") else {
            return nil
        }

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 17, weight: .black, scale: .large)
        let configured = base.withSymbolConfiguration(symbolConfig) ?? base

        let canvasSize = NSSize(width: 18, height: 18)
        let symbolSize = configured.size
        guard symbolSize.width > 0, symbolSize.height > 0 else {
            configured.isTemplate = true
            return configured
        }

        // Keep aspect ratio while slightly enlarging to improve optical size.
        let fitScale = min(canvasSize.width / symbolSize.width, canvasSize.height / symbolSize.height) * 1.08
        let drawSize = NSSize(width: symbolSize.width * fitScale, height: symbolSize.height * fitScale)
        let drawRect = NSRect(
            x: (canvasSize.width - drawSize.width) / 2,
            y: (canvasSize.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )

        let canvas = NSImage(size: canvasSize)
        canvas.lockFocus()
        configured.draw(
            in: drawRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        canvas.unlockFocus()
        canvas.isTemplate = true
        return canvas
    }
    #endif
    #endif
}

#if os(macOS)
@MainActor
private final class CopoolAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        NSApplication.shared.registerForRemoteNotifications()
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        _ = application
        _ = deviceToken
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String : Any]) {
        _ = application
        handleRemoteNotification(userInfo)
    }
}
#elseif os(iOS)
@MainActor
private final class CopoolAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
    ) -> Bool {
        _ = launchOptions
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        _ = application
        _ = deviceToken
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable : Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        _ = application
        let handled = handleRemoteNotification(userInfo)
        completionHandler(handled ? .newData : .noData)
    }
}
#endif

@discardableResult
private func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
    let payload = userInfo.reduce(into: [String: Any]()) { partialResult, entry in
        if let key = entry.key as? String {
            partialResult[key] = entry.value
        }
    }

    guard let notification = CKNotification(fromRemoteNotificationDictionary: payload) else {
        return false
    }

    if notification.subscriptionID == CloudKitCurrentAccountSelectionSyncService.pushSubscriptionID {
        NotificationCenter.default.post(name: .copoolCurrentAccountSelectionPushDidArrive, object: nil)
        return true
    }

    if notification.subscriptionID == CloudKitProxyControlSyncService.pushSubscriptionID {
        NotificationCenter.default.post(name: .copoolProxyControlPushDidArrive, object: nil)
        return true
    }

    return false
}
