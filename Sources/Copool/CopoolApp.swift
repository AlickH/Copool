import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

@main
struct CopoolApp: App {
    private let container: AppContainer
    @StateObject private var trayModel: TrayMenuModel

    init() {
        let container = AppContainer.liveOrCrash()
        self.container = container
        _trayModel = StateObject(wrappedValue: container.trayModel)
        Task { @MainActor in
            container.trayModel.startBackgroundRefresh()
            await container.settingsModel.loadIfNeeded()
            await container.proxyModel.bootstrapOnAppLaunch(using: container.settingsModel.settings)
        }
    }

    var body: some Scene {
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
    }

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
}
