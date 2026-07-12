import AppKit
import SwiftUI

/// Brand logo for a provider, falling back to the snapshot's SF Symbol when
/// no bundled asset matches the service id (e.g. the Anthropic admin card).
/// Shared by the app and the widget extension — both bundles ship the
/// ProviderIcons catalog, so `NSImage(named:)` resolves in each.
struct ProviderIconView: View {
    let serviceID: String
    let sfFallback: String
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let assetName {
                Image(assetName)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: sfFallback)
                    .font(.system(size: size * 0.85, weight: .medium))
            }
        }
        .frame(width: size, height: size)
    }

    private var assetName: String? {
        let name = "ProviderIcon-\(serviceID)"
        return NSImage(named: name) != nil ? name : nil
    }
}
