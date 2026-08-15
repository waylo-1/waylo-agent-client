import Cocoa

/// Phase 1 coordinate self-test. Triggered by Cmd+Shift+T.
///
/// Picks a known AX element in the current target app (a real button whose
/// position the system reports authoritatively), logs its AX frame, and places
/// the debug dot on its center. If the transform pipeline is correct the red
/// dot should land exactly on that button. Any offset visible on screen is the
/// bug we are hunting, and the logs give us the exact numbers.
@MainActor
enum CoordinateTester {

    static func runCoordinateTest() {
        DebugLogger.log("COORD-TEST", "=== running coordinate self-test ===")

        let target = TargetAppTracker.shared.targetName
        DebugLogger.log("COORD-TEST", "target app = '\(target)'")

        let elements = AccessibilityReader.shared.getTargetAppElements()
        DebugLogger.log("COORD-TEST", "AX elements found = \(elements.count)")

        // Prefer a real, on-screen button with a non-zero frame and a label.
        guard let probe = elements.first(where: {
            $0.role == "AXButton" && $0.frame.width > 4 && $0.frame.height > 4 && !$0.title.isEmpty
        }) ?? elements.first(where: { $0.frame.width > 4 && $0.frame.height > 4 }) else {
            DebugLogger.log("COORD-TEST", "no usable AX element — open a normal app (Finder/Safari) and retry")
            DebugState.shared.update(layer: "COORD-TEST: no element")
            return
        }

        let axCenter = probe.center
        DebugLogger.log("COORD-TEST",
            "probe role=\(probe.role) title='\(probe.title)' frame=\(rectStr(probe.frame)) axCenter=(\(Int(axCenter.x)), \(Int(axCenter.y)))")

        // Log the transform math so we can see exactly where the dot will land.
        let cocoa = ScreenCoordinates.axToCocoa(axCenter)
        DebugLogger.log("COORD-TEST",
            "primaryHeight=\(Int(ScreenCoordinates.primaryHeight)) axCenter.y=\(Int(axCenter.y)) → cocoa=(\(Int(cocoa.x)), \(Int(cocoa.y)))")
        DebugLogger.log("COORD-TEST",
            "globalFrame=\(rectStr(ScreenCoordinates.globalFrame))")

        DebugState.shared.update(layer: "COORD-TEST '\(probe.title)'", dot: axCenter)

        // Place the dot. It should sit dead-center on the probed button.
        OverlayWindowController.shared.showDot(at: axCenter, caption: "TEST: \(probe.title)")
        DebugLogger.log("COORD-TEST", "dot placed — verify it sits on '\(probe.title)'. === end ===")
    }

    private static func rectStr(_ r: CGRect) -> String {
        String(format: "(%.0f, %.0f, %.0fx%.0f)", r.origin.x, r.origin.y, r.width, r.height)
    }
}
