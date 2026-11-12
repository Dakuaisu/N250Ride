/// Hex input and output for the Bluetooth console.
public enum HexBytes {
    /// Accepts "11 47 00", "0x11,0x47", "114700"; nil for odd digits or other characters.
    public static func parse(_ text: String) -> [UInt8]? {
        var digits = text.lowercased().replacingOccurrences(of: "0x", with: "")
        digits.removeAll { $0 == " " || $0 == "," || $0 == ":" || $0 == "-" || $0 == "\n" || $0 == "\t" }
        guard !digits.isEmpty, digits.count % 2 == 0, digits.allSatisfy(\.isHexDigit) else { return nil }
        var bytes: [UInt8] = []
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            bytes.append(UInt8(digits[index..<next], radix: 16)!)
            index = next
        }
        return bytes
    }

    public static func format(_ bytes: [UInt8], grouping: Int = 1) -> String {
        bytes.enumerated().map { offset, byte in
            let text = String(byte, radix: 16, uppercase: true)
            let padded = text.count == 1 ? "0" + text : text
            return offset > 0 && offset % grouping == 0 ? " " + padded : padded
        }.joined()
    }
}
