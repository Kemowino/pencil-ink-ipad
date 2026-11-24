import Foundation
import CoreGraphics

#if canImport(UIKit)
import UIKit
import SwiftUI
#elseif canImport(AppKit)
import AppKit
#endif

/// Unified "Studio Craft" v5.0.0 design system shared between macOS (AppKit) and iPadOS (SwiftUI/UIKit).
/// All chrome surfaces are strictly opaque so Intel macOS avoids expensive WindowServer live-blur compositing.
enum DesignTokens {
    struct RGBA {
        let r: CGFloat
        let g: CGFloat
        let b: CGFloat
        let a: CGFloat
        init(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1.0) {
            self.r = r; self.g = g; self.b = b; self.a = a
        }
    }

    // Dark Mode Palette (Deep Obsidian Slate — high contrast, low glare for long study sessions)
    static let darkCanvasBackdrop  = RGBA(0.086, 0.094, 0.114) // #16181D
    static let darkChromePrimary   = RGBA(0.114, 0.125, 0.157) // #1D2028
    static let darkChromeSecondary = RGBA(0.094, 0.106, 0.133) // #181B22
    static let darkTabTrack        = RGBA(0.075, 0.082, 0.102) // #13151A
    static let darkCardSurface     = RGBA(0.133, 0.149, 0.188) // #222630
    static let darkElevatedPill    = RGBA(0.149, 0.169, 0.216) // #262B37
    static let darkSidebarBg       = RGBA(0.102, 0.112, 0.141) // #1A1C24
    static let darkHairline        = RGBA(1.0, 1.0, 1.0, 0.095)
    static let darkAccent          = RGBA(0.231, 0.510, 0.965) // #3B82F6

    // Light Mode Palette (Clean Studio Paper — crisp white elevation on cool mist canvas)
    static let lightCanvasBackdrop  = RGBA(0.922, 0.933, 0.949) // #EBEEF2
    static let lightChromePrimary   = RGBA(1.000, 1.000, 1.000) // #FFFFFF
    static let lightChromeSecondary = RGBA(0.961, 0.969, 0.980) // #F5F7FA
    static let lightTabTrack        = RGBA(0.894, 0.906, 0.929) // #E4E7ED
    static let lightCardSurface     = RGBA(1.000, 1.000, 1.000) // #FFFFFF
    static let lightElevatedPill    = RGBA(1.000, 1.000, 1.000) // #FFFFFF
    static let lightSidebarBg       = RGBA(0.949, 0.957, 0.973) // #F2F4F8
    static let lightHairline        = RGBA(0.059, 0.090, 0.165, 0.095)
    static let lightAccent          = RGBA(0.145, 0.388, 0.922) // #2563EB

    // Semantic Accents
    static let warmGoldRGB        = RGBA(0.961, 0.620, 0.043) // #F59E0B (Bookmarks, Favorites, Hobonichi)
    static let emeraldRGB         = RGBA(0.063, 0.725, 0.506) // #10B981 (Synced / Healthy)
    static let coralRedRGB        = RGBA(0.937, 0.267, 0.267) // #EF4444 (Errors / Destructive)
    static let skyFolderTopRGB    = RGBA(0.329, 0.678, 0.980)
    static let skyFolderBottomRGB = RGBA(0.184, 0.518, 0.902)

    // Radii & Motion
    static let radiusSmall: CGFloat  = 6
    static let radiusMedium: CGFloat = 10
    static let radiusLarge: CGFloat  = 14
    static let radiusPill: CGFloat   = 999
    static let motionQuick: TimeInterval = 0.15
    static let motionStandard: TimeInterval = 0.22

    #if canImport(AppKit)
    private static func dynamicNS(light: RGBA, dark: RGBA) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(red: c.r, green: c.g, blue: c.b, alpha: c.a)
        }
    }

    static let nsCanvasBackdrop  = dynamicNS(light: lightCanvasBackdrop, dark: darkCanvasBackdrop)
    static let nsChromePrimary   = dynamicNS(light: lightChromePrimary, dark: darkChromePrimary)
    static let nsChromeSecondary = dynamicNS(light: lightChromeSecondary, dark: darkChromeSecondary)
    static let nsCardSurface     = dynamicNS(light: lightCardSurface, dark: darkCardSurface)
    static let nsElevatedPill    = dynamicNS(light: lightElevatedPill, dark: darkElevatedPill)
    static let nsSidebarBg       = dynamicNS(light: lightSidebarBg, dark: darkSidebarBg)
    static let nsHairline        = dynamicNS(light: lightHairline, dark: darkHairline)
    static let nsAccent          = dynamicNS(light: lightAccent, dark: darkAccent)
    static let nsWarmGold        = NSColor(red: warmGoldRGB.r, green: warmGoldRGB.g, blue: warmGoldRGB.b, alpha: 1.0)
    static let nsEmerald         = NSColor(red: emeraldRGB.r, green: emeraldRGB.g, blue: emeraldRGB.b, alpha: 1.0)
    static let nsCoralRed        = NSColor(red: coralRedRGB.r, green: coralRedRGB.g, blue: coralRedRGB.b, alpha: 1.0)
    static let nsPageBorder      = dynamicNS(light: RGBA(0.059, 0.090, 0.165, 0.14), dark: RGBA(1, 1, 1, 0.08))
    #endif

    #if canImport(UIKit)
    private static func dynamicUI(light: RGBA, dark: RGBA) -> UIColor {
        UIColor { traits in
            let c = (traits.userInterfaceStyle == .dark) ? dark : light
            return UIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a)
        }
    }

    static let uiCanvasBackdrop  = dynamicUI(light: lightCanvasBackdrop, dark: darkCanvasBackdrop)
    static let uiChromePrimary   = dynamicUI(light: lightChromePrimary, dark: darkChromePrimary)
    static let uiChromeSecondary = dynamicUI(light: lightChromeSecondary, dark: darkChromeSecondary)
    static let uiCardSurface     = dynamicUI(light: lightCardSurface, dark: darkCardSurface)
    static let uiElevatedPill    = dynamicUI(light: lightElevatedPill, dark: darkElevatedPill)
    static let uiHairline        = dynamicUI(light: lightHairline, dark: darkHairline)
    static let uiAccent          = dynamicUI(light: lightAccent, dark: darkAccent)

    static func color(_ light: RGBA, dark: RGBA, scheme: ColorScheme) -> Color {
        let c = (scheme == .dark) ? dark : light
        return Color(red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }

    static func canvasBackdrop(_ scheme: ColorScheme) -> Color {
        color(lightCanvasBackdrop, dark: darkCanvasBackdrop, scheme: scheme)
    }
    static func chromePrimary(_ scheme: ColorScheme) -> Color {
        color(lightChromePrimary, dark: darkChromePrimary, scheme: scheme)
    }
    static func chromeSecondary(_ scheme: ColorScheme) -> Color {
        color(lightChromeSecondary, dark: darkChromeSecondary, scheme: scheme)
    }
    static func tabTrack(_ scheme: ColorScheme) -> Color {
        color(lightTabTrack, dark: darkTabTrack, scheme: scheme)
    }
    static func cardSurface(_ scheme: ColorScheme) -> Color {
        color(lightCardSurface, dark: darkCardSurface, scheme: scheme)
    }
    static func elevatedPill(_ scheme: ColorScheme) -> Color {
        color(lightElevatedPill, dark: darkElevatedPill, scheme: scheme)
    }
    static func hairline(_ scheme: ColorScheme) -> Color {
        color(lightHairline, dark: darkHairline, scheme: scheme)
    }
    static func accent(_ scheme: ColorScheme) -> Color {
        color(lightAccent, dark: darkAccent, scheme: scheme)
    }
    static let warmGold = Color(red: warmGoldRGB.r, green: warmGoldRGB.g, blue: warmGoldRGB.b)
    static let emerald  = Color(red: emeraldRGB.r, green: emeraldRGB.g, blue: emeraldRGB.b)
    static let coralRed = Color(red: coralRedRGB.r, green: coralRedRGB.g, blue: coralRedRGB.b)
    #endif
}
