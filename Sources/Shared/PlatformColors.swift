import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Cross-platform color helpers for UIKit system colors.
/// On iOS/iPadOS, these map directly to UIColor system colors.
/// On macOS, they map to equivalent NSColor or hardcoded values.
public enum PlatformColor {
    public static var systemGray6: Color {
        #if canImport(UIKit)
        return Color(.systemGray6)
        #else
        return Color(NSColor.controlBackgroundColor)
        #endif
    }

    public static var systemGray5: Color {
        #if canImport(UIKit)
        return Color(.systemGray5)
        #else
        return Color(NSColor.separatorColor)
        #endif
    }

    public static var systemBackground: Color {
        #if canImport(UIKit)
        return Color(.systemBackground)
        #else
        return Color(NSColor.windowBackgroundColor)
        #endif
    }
}
