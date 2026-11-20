import CoreGraphics
import Foundation

/// Pure screen-geometry placement helper that guarantees the floating menu bar panel
/// always renders cleanly below the macOS menu bar & MacBook camera notch, even when
/// macOS pushes the status item icon behind the notch in a crowded menu bar.
public enum MenuBarPositioner {
    public struct Placement: Equatable, Sendable {
        public let origin: CGPoint
        public let statusItemOccludedByNotch: Bool

        public init(origin: CGPoint, statusItemOccludedByNotch: Bool) {
            self.origin = origin
            self.statusItemOccludedByNotch = statusItemOccludedByNotch
        }
    }

    /// Computes AppKit (bottom-left origin) coordinates for a panel of `panelSize`.
    /// - Parameters:
    ///   - buttonScreenRect: The status bar button's frame in AppKit screen coordinates (optional if unavailable).
    ///   - screenFrame: Full `NSScreen.frame`.
    ///   - visibleFrame: `NSScreen.visibleFrame` (excludes menu bar, notch, and dock).
    ///   - auxLeft: `NSScreen.auxiliaryTopLeftArea` (present on notched MacBooks).
    ///   - auxRight: `NSScreen.auxiliaryTopRightArea` (present on notched MacBooks).
    ///   - panelSize: Desired width and height of the floating panel.
    public static func computePlacement(
        buttonScreenRect: CGRect?,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        auxLeft: CGRect?,
        auxRight: CGRect?,
        panelSize: CGSize,
        margin: CGFloat = 10,
        topGap: CGFloat = 8
    ) -> Placement {
        // Guaranteed Y strictly below menu bar & notch (AppKit Y grows upward)
        let maxOriginY = visibleFrame.maxY - topGap - panelSize.height
        let y = max(visibleFrame.minY + margin, maxOriginY)

        // Determine whether the status item button is actually visible or hidden behind the notch / off-screen
        var occluded = true
        var anchorMidX: CGFloat? = nil

        if let btn = buttonScreenRect, btn.width > 1, btn.height > 1 {
            let horizontallyOnScreen = btn.maxX > screenFrame.minX + 2 && btn.minX < screenFrame.maxX - 2
            let verticallyInMenuBar = btn.midY >= visibleFrame.maxY - 6 && btn.midY <= screenFrame.maxY + 6

            var insideNotch = false
            if let l = auxLeft, let r = auxRight, r.minX > l.maxX {
                let notchMinX = l.maxX
                let notchMaxX = r.minX
                // Consider occluded if more than a sliver overlaps the physical notch dead zone
                insideNotch = btn.minX < notchMaxX - 2 && btn.maxX > notchMinX + 2
            }

            if horizontallyOnScreen && verticallyInMenuBar && !insideNotch {
                occluded = false
                anchorMidX = btn.midX
            }
        }

        let minX = visibleFrame.minX + margin
        let maxX = max(minX, visibleFrame.maxX - panelSize.width - margin)

        let rawX: CGFloat
        if let midX = anchorMidX {
            rawX = midX - panelSize.width * 0.5
        } else {
            // Status item is hidden behind the notch or off-screen: anchor cleanly at top-right below menu bar
            rawX = maxX
        }

        let x = min(max(rawX, minX), maxX)
        return Placement(origin: CGPoint(x: round(x), y: round(y)), statusItemOccludedByNotch: occluded)
    }
}
