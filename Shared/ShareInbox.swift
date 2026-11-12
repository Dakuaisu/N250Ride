import UIKit

/// Hands a shared link or text from the Share extension to the app. Uses a named
/// pasteboard, which apps from the same developer team can share without extra
/// entitlements; the app empties it as soon as it reads it.
enum ShareInbox {
    private static let name = UIPasteboard.Name("com.n250ride.share-inbox")
    private static let type = "public.utf8-plain-text"

    static func put(_ text: String) {
        UIPasteboard(name: name, create: true)?.setValue(text, forPasteboardType: type)
    }

    static func take() -> String? {
        guard let board = UIPasteboard(name: name, create: false),
              let text = board.value(forPasteboardType: type) as? String, !text.isEmpty else { return nil }
        board.items = []
        return text
    }
}
