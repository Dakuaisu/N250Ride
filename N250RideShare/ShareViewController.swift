import Observation
import RideCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "Share → N250 Ride" from Apple Maps, Google Maps, WhatsApp and others. Finds a
/// location in what was shared, leaves it for the app, and asks the rider to open
/// N250 Ride (iOS does not let share extensions open their app).
final class ShareViewController: UIViewController {
    private let status = ShareStatus()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareView(status: status) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        })
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        Task { await collect(providers) }
    }

    /// At most this many attachments are read; each is cut to the parser's size limit.
    static let maxProviders = 8

    private func collect(_ providers: [NSItemProvider]) async {
        var texts: [String] = []
        for provider in providers.prefix(Self.maxProviders) {
            guard let text = await Self.text(from: provider) else { continue }
            let bounded = String(text.utf8.prefix(MapLinkParser.maxInputBytes)) ?? ""
            if MapLinkParser.parse(bounded) != nil {
                return deliver(bounded)
            }
            texts.append(bounded)
        }
        let joined = String(texts.joined(separator: " ").utf8.prefix(MapLinkParser.maxInputBytes)) ?? ""
        if MapLinkParser.parse(joined) != nil {
            deliver(joined)
        } else {
            status.result = .noLocation
        }
    }

    private func deliver(_ text: String) {
        status.result = ShareInbox.put(text) ? .sent : .failed
    }

    private static func text(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url?.absoluteString) }
            } else if provider.canLoadObject(ofClass: String.self) {
                _ = provider.loadObject(ofClass: String.self) { text, _ in continuation.resume(returning: text) }
            } else {
                continuation.resume(returning: nil)
            }
        }
    }
}

@MainActor
@Observable
final class ShareStatus {
    enum Result { case working, sent, noLocation, failed }
    var result = Result.working
}

struct ShareView: View {
    let status: ShareStatus
    let done: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            switch status.result {
            case .working:
                ProgressView("Reading location…")
            case .sent:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(.green)
                Text("Sent to N250 Ride").font(.title2.weight(.semibold))
                Text("Open N250 Ride soon to keep it: until the app opens, a phone restart can lose it.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 56)).foregroundStyle(.orange)
                Text("Couldn't hand it to N250 Ride").font(.title2.weight(.semibold))
                Text("Copy the link and paste it in N250 Ride instead.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            case .noLocation:
                Image(systemName: "mappin.slash").font(.system(size: 56)).foregroundStyle(.orange)
                Text("No location found").font(.title2.weight(.semibold))
                Text("Share a place from a maps app, or a message with a map link.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            Button("Done", action: done)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
