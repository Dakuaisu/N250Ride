import UIKit

/// Hands a shared link or text from the Share extension to the app through a named
/// pasteboard. This is a short-lived hand-off, not storage: iOS may drop it (for
/// example on restart). The app copies it into its own inbox first and only then
/// clears it. A durable extension queue needs an App Group, which this build does not use.
enum ShareInbox {
    private static let name = UIPasteboard.Name("com.n250ride.share-inbox")
    private static let type = "public.utf8-plain-text"

    static func put(_ text: String) {
        UIPasteboard(name: name, create: true)?.setValue(text, forPasteboardType: type)
    }

    static func peek() -> String? {
        guard let board = UIPasteboard(name: name, create: false),
              let text = board.value(forPasteboardType: type) as? String, !text.isEmpty else { return nil }
        return text
    }

    static func clear() {
        UIPasteboard(name: name, create: false)?.items = []
    }
}
