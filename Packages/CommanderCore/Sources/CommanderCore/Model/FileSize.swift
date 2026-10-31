import Foundation

/// Compact decimal sizes for panel rows and the key column.
public enum FileSize {
    public static func format(_ bytes: Int64) -> String {
        let value = Double(bytes)
        switch bytes {
        // Thresholds sit where rounding would otherwise show 1000.0 of the smaller unit.
        case 999_950_000...: return String(format: "%.2f GB", value / 1e9)
        case 999_950...: return String(format: "%.1f MB", value / 1e6)
        case 1_000...: return String(format: "%.1f KB", value / 1e3)
        default: return "\(bytes) B"
        }
    }
}
