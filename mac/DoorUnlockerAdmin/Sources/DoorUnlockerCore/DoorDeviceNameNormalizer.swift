import Foundation

public enum DoorDeviceNameNormalizer {
    public static let maximumDeviceNameLength = 24

    public static func normalized(_ name: String, fallback: String, maximumLength: Int = maximumDeviceNameLength) -> String {
        let normalized = name
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{201B}", with: "'")
            .replacingOccurrences(of: "\u{2032}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{201E}", with: "\"")
            .replacingOccurrences(of: "\u{2033}", with: "\"")
            .replacingOccurrences(of: "\u{2010}", with: "-")
            .replacingOccurrences(of: "\u{2011}", with: "-")
            .replacingOccurrences(of: "\u{2012}", with: "-")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "-")
            .replacingOccurrences(of: "\u{2026}", with: "...")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = normalized.isEmpty ? fallback : normalized
        let ascii = fallbackName.unicodeScalars.compactMap { scalar -> String? in
            scalar.isASCII && scalar.value >= 32 && scalar.value <= 126 ? String(scalar) : nil
        }

        return String(ascii.joined().prefix(maximumLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
