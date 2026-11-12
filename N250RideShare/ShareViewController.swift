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

    private func collect(_ providers: [NSItemProvider]) async {
        var texts: [String] = []
        for provider in providers {
            if let text = await Self.text(from: provider) { texts.append(text) }
        }
        let candidates = texts + [texts.joined(separator: " ")]
        if let found = candidates.first(where: { MapLinkParser.parse($0) != nil }) {
            ShareInbox.put(found)
            status.result = .sent
        } else {
            status.result = .noLocation
        }
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
    enum Result { case working, sent, noLocation }
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
                Text("Open N250 Ride to choose a route.").foregroundStyle(.secondary)
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
