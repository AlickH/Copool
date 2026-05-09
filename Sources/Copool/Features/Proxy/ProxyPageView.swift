import SwiftUI

struct ProxyPageView: View {
    @ObservedObject var model: ProxyPageModel

    var body: some View {
        ScrollView {
            VStack(spacing: LayoutRules.sectionSpacing) {
                ApiProxySectionView(model: model)
                RemoteServersSectionView(model: model)
                PublicAccessSection(model: model, onCopy: PlatformClipboard.copy)
            }
            .padding(LayoutRules.pagePadding)
        }
        .scrollIndicators(.hidden)
        .task {
            await model.loadIfNeeded()
        }
    }

}
