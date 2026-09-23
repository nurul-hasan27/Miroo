//
//  EdgeToEdgeTests.swift
//  Miroo
//
//  Phase 11 Pre-Merge: True Edge-to-Edge iPhone Display Layout Verification Suite.
//  Verifies that the Mac virtual display occupies the maximum physical iPhone display area,
//  protects the physical notch, eliminates software safe area black borders (e.g. bottom home bar),
//  prevents symmetric landscape margin bugs, preserves exact aspect ratio across all display modes,
//  and provides pixel-perfect touch coordinate mapping without drift.
//

import Foundation
import CoreGraphics
import MirooNetworking

func assertCondition(_ condition: Bool, _ message: String) {
    if !condition {
        print("❌ ASSERTION FAILED: \(message)")
        exit(1)
    }
}

final class EdgeToEdgeTestSuite {
    static func runAll() {
        print("==================================================================")
        print("     Miroo: True Edge-to-Edge Layout Verification Suite           ")
        print("==================================================================")

        test1_PortraitBottomEdgeReachesPhysicalBoundary()
        test2_LandscapeNotchLeft_NonNotchReachesEdge()
        test3_LandscapeNotchRight_NonNotchReachesEdge()
        test4_LandscapeSymmetricInsetsRegression_OrientationRight()
        test5_LandscapeSymmetricInsetsRegression_OrientationLeft()
        test6_ArbitraryDisplayResolutionsAspectFidelity()
        test7_TouchCoordinateMappingEdgePrecision()
        test8_iPadAndNoNotchEdgeToEdge()
        test9_DynamicScaleFactors_1x_2x_3x()
        test10_ZeroSizeSafety()

        print("\n==================================================================")
        print("🎉 ALL 10 TRUE EDGE-TO-EDGE LAYOUT TESTS PASSED SUCCESSFULLY!")
        print("==================================================================")
    }

    // MARK: - Test 1: Portrait Mode Bottom Edge Reaches Physical Boundary
    static func test1_PortraitBottomEdgeReachesPhysicalBoundary() {
        print("\n[Test 1] Portrait Mode: Bottom Edge Reaches Physical Screen Edge...")
        // iPhone 11 Portrait: 414 x 896 pt, @2x scale -> 828 x 1792 px
        // UIKit reports safe area insets: top: 48 pt (notch), bottom: 34 pt (home bar)
        let viewBounds = CGRect(x: 0, y: 0, width: 414, height: 896)
        let drawableSize = CGSize(width: 828, height: 1792)
        let insets = UIEdgeInsets(top: 48, left: 0, bottom: 34, right: 0)
        let videoSize = CGSize(width: 1170, height: 2532) // Portrait virtual display

        let layout = RenderViewportLayout.compute(
            viewBounds: viewBounds,
            safeAreaInsets: insets,
            drawableSize: drawableSize,
            videoSize: videoSize,
            interfaceOrientation: .portrait
        )

        // 1. Hardware insets must exclude notch at top, but NOT bottom home indicator
        assertCondition(layout.safeAreaInsets.top == 48, "Top notch inset must be preserved (48 pt)")
        assertCondition(layout.safeAreaInsets.bottom == 0, "Bottom home indicator inset must be 0 pt (not excluded)")
        assertCondition(layout.safeAreaInsets.left == 0, "Left inset must be 0 in portrait")
        assertCondition(layout.safeAreaInsets.right == 0, "Right inset must be 0 in portrait")

        // 2. Usable height must be 896 - 48 = 848 pt (1696 px)
        assertCondition(layout.usableRectPoints.height == 848, "Usable height in points must be 848 pt")
        assertCondition(layout.usableRectPixels.height == 1696, "Usable height in pixels must be 1696 px")

        // 3. Render rect must extend all the way down to the physical bottom edge
        let bottomPhysicalEdge = layout.renderRectPixels.maxY
        assertCondition(abs(bottomPhysicalEdge - drawableSize.height) < 0.001,
                        "Video rendering must touch the physical bottom edge (1792 px), got \(bottomPhysicalEdge)")

        let bottomPointsEdge = layout.contentRectPoints.maxY
        assertCondition(abs(bottomPointsEdge - viewBounds.height) < 0.001,
                        "Content rect points must touch the physical bottom edge (896 pt), got \(bottomPointsEdge)")

        // 4. Top notch must be completely protected
        assertCondition(layout.renderRectPixels.minY >= 48 * 2, "Top notch region (0..96px) must be protected")

        // 5. Mac aspect ratio must be strictly preserved
        let macAspect = videoSize.width / videoSize.height
        let renderAspect = layout.renderRectPixels.width / layout.renderRectPixels.height
        assertCondition(abs(renderAspect - macAspect) < 0.0001, "Aspect ratio must be bit-for-bit exact")

        print("  ✓ Video rendering reaches physical bottom edge (1792 px) while notch is fully protected.")
    }

    // MARK: - Test 2: Landscape Notch Left, Non-Notch Reaches Edge
    static func test2_LandscapeNotchLeft_NonNotchReachesEdge() {
        print("\n[Test 2] Landscape Mode (Notch on Left): Non-Notch Side Reaches Screen Edge...")
        // iPhone 11 Landscape: 896 x 414 pt, @2x scale -> 1792 x 828 px
        // Notch physically on left: left: 48 pt, bottom: 21 pt (home bar)
        let viewBounds = CGRect(x: 0, y: 0, width: 896, height: 414)
        let drawableSize = CGSize(width: 1792, height: 828)
        let insets = UIEdgeInsets(top: 0, left: 48, bottom: 21, right: 0)
        let videoSize = CGSize(width: 2532, height: 1170) // Landscape virtual display (2.164:1)

        let layout = RenderViewportLayout.compute(
            viewBounds: viewBounds,
            safeAreaInsets: insets,
            drawableSize: drawableSize,
            videoSize: videoSize,
            interfaceOrientation: .landscapeRight
        )

        // 1. Insets verification: Only notch side excluded, top/bottom/right are 0
        assertCondition(layout.safeAreaInsets.left == 48, "Left notch inset preserved (48 pt)")
        assertCondition(layout.safeAreaInsets.right == 0, "Right non-notch edge must be 0 pt")
        assertCondition(layout.safeAreaInsets.top == 0, "Top edge in landscape must be 0 pt")
        assertCondition(layout.safeAreaInsets.bottom == 0, "Bottom edge in landscape must be 0 pt")

        // 2. Video right edge must reach the exact physical right screen edge (1792 px)
        let rightEdgePx = layout.renderRectPixels.maxX
        assertCondition(abs(rightEdgePx - drawableSize.width) < 0.001,
                        "Video rendering must touch the physical right edge (1792 px), got \(rightEdgePx)")

        // 3. Notch on left must be protected
        assertCondition(layout.renderRectPixels.minX == 48 * 2, "Notch region (0..96px) on left must be protected")

        // 4. Strict aspect ratio
        let macAspect = videoSize.width / videoSize.height
        let renderAspect = layout.renderRectPixels.width / layout.renderRectPixels.height
        assertCondition(abs(renderAspect - macAspect) < 0.0001, "Landscape aspect ratio exact")

        print("  ✓ Non-notch edge extends cleanly to right physical border with zero phantom margin.")
    }

    // MARK: - Test 3: Landscape Notch Right, Non-Notch Reaches Edge
    static func test3_LandscapeNotchRight_NonNotchReachesEdge() {
        print("\n[Test 3] Landscape Mode (Notch on Right): Non-Notch Side Reaches Screen Edge...")
        // iPhone 11 Landscape: 896 x 414 pt, @2x scale -> 1792 x 828 px
        // Notch physically on right: right: 48 pt, bottom: 21 pt (home bar)
        let viewBounds = CGRect(x: 0, y: 0, width: 896, height: 414)
        let drawableSize = CGSize(width: 1792, height: 828)
        let insets = UIEdgeInsets(top: 0, left: 0, bottom: 21, right: 48)
        let videoSize = CGSize(width: 2532, height: 1170)

        let layout = RenderViewportLayout.compute(
            viewBounds: viewBounds,
            safeAreaInsets: insets,
            drawableSize: drawableSize,
            videoSize: videoSize,
            interfaceOrientation: .landscapeLeft
        )

        // 1. Insets verification: Only right notch excluded
        assertCondition(layout.safeAreaInsets.right == 48, "Right notch inset preserved (48 pt)")
        assertCondition(layout.safeAreaInsets.left == 0, "Left non-notch edge must be 0 pt")
        assertCondition(layout.safeAreaInsets.top == 0, "Top edge in landscape must be 0 pt")
        assertCondition(layout.safeAreaInsets.bottom == 0, "Bottom edge in landscape must be 0 pt")

        // 2. Video left edge must reach the exact physical left screen edge (0 px)
        let leftEdgePx = layout.renderRectPixels.minX
        assertCondition(abs(leftEdgePx - 0) < 0.001, "Video rendering must touch the physical left edge (0 px)")

        // 3. Notch on right protected: video maxX must be 1792 - 96 = 1696 px
        let rightEdgePx = layout.renderRectPixels.maxX
        assertCondition(abs(rightEdgePx - 1696) < 0.001, "Notch region on right (1696..1792px) must be protected")

        print("  ✓ Video touches left physical border (x=0) and safely stops before notch on right.")
    }

    // MARK: - Test 4: Symmetrical Landscape Inset Bug Regression (Home button Right)
    static func test4_LandscapeSymmetricInsetsRegression_OrientationRight() {
        print("\n[Test 4] Symmetrical Insets Regression Guard (Orientation: LandscapeRight)...")
        // UIKit often reports symmetric 48/48 insets in landscape.
        // Miroo must disambiguate and NOT add padding to the non-notch side!
        let viewBounds = CGRect(x: 0, y: 0, width: 896, height: 414)
        let drawableSize = CGSize(width: 1792, height: 828)
        let symmetricInsets = UIEdgeInsets(top: 0, left: 48, bottom: 21, right: 48)
        let videoSize = CGSize(width: 2532, height: 1170)

        let layout = RenderViewportLayout.compute(
            viewBounds: viewBounds,
            safeAreaInsets: symmetricInsets,
            drawableSize: drawableSize,
            videoSize: videoSize,
            interfaceOrientation: .landscapeRight // Notch on left
        )

        assertCondition(layout.safeAreaInsets.left == 48, "Left notch isolated to 48 pt")
        assertCondition(layout.safeAreaInsets.right == 0, "Right edge stripped of phantom margin (0 pt)")
        assertCondition(abs(layout.renderRectPixels.maxX - drawableSize.width) < 0.001,
                        "Right edge reaches physical screen border (1792 px)")
        print("  ✓ Symmetrical UIKit margin bug successfully eliminated for LandscapeRight.")
    }

    // MARK: - Test 5: Symmetrical Landscape Inset Bug Regression (Home button Left)
    static func test5_LandscapeSymmetricInsetsRegression_OrientationLeft() {
        print("\n[Test 5] Symmetrical Insets Regression Guard (Orientation: LandscapeLeft)...")
        let viewBounds = CGRect(x: 0, y: 0, width: 896, height: 414)
        let drawableSize = CGSize(width: 1792, height: 828)
        let symmetricInsets = UIEdgeInsets(top: 0, left: 48, bottom: 21, right: 48)
        let videoSize = CGSize(width: 2532, height: 1170)

        let layout = RenderViewportLayout.compute(
            viewBounds: viewBounds,
            safeAreaInsets: symmetricInsets,
            drawableSize: drawableSize,
            videoSize: videoSize,
            interfaceOrientation: .landscapeLeft // Notch on right
        )

        assertCondition(layout.safeAreaInsets.right == 48, "Right notch isolated to 48 pt")
        assertCondition(layout.safeAreaInsets.left == 0, "Left edge stripped of phantom margin (0 pt)")
        assertCondition(abs(layout.renderRectPixels.minX - 0) < 0.001,
                        "Left edge reaches physical screen border (0 px)")
        print("  ✓ Symmetrical UIKit margin bug successfully eliminated for LandscapeLeft.")
    }

    // MARK: - Test 6: Arbitrary Display Resolutions Aspect Fidelity
    static func test6_ArbitraryDisplayResolutionsAspectFidelity() {
        print("\n[Test 6] Arbitrary Aspect Ratios & Non-Standard Display Fidelity...")
        let testResolutions: [(String, CGSize)] = [
            ("16:9 Standard", CGSize(width: 1920, height: 1080)),
            ("16:10 MacBook", CGSize(width: 1920, height: 1200)),
            ("16:10 MacBook Air", CGSize(width: 1440, height: 900)),
            ("4:3 Legacy / iPad", CGSize(width: 1600, height: 1200)),
            ("21:9 Ultra-Wide", CGSize(width: 2560, height: 1080)),
            ("32:9 Super Ultra-Wide", CGSize(width: 5120, height: 1440)),
            ("3:2 Surface / Classic", CGSize(width: 3000, height: 2000)),
            ("Tall Portrait", CGSize(width: 1080, height: 2400))
        ]

        let viewBounds = CGRect(x: 0, y: 0, width: 896, height: 414)
        let drawableSize = CGSize(width: 1792, height: 828)
        let insets = UIEdgeInsets(top: 0, left: 48, bottom: 21, right: 0)

        for (name, videoSize) in testResolutions {
            let layout = RenderViewportLayout.compute(
                viewBounds: viewBounds,
                safeAreaInsets: insets,
                drawableSize: drawableSize,
                videoSize: videoSize,
                interfaceOrientation: .landscapeRight
            )

            let inputAspect = videoSize.width / videoSize.height
            let renderedAspect = layout.renderRectPixels.width / layout.renderRectPixels.height
            let aspectError = abs(renderedAspect - inputAspect)

            assertCondition(aspectError < 0.0001,
                            "Aspect ratio must be preserved for \(name), expected \(inputAspect), got \(renderedAspect)")
            assertCondition(layout.renderRectPixels.width <= layout.usableRectPixels.width + 0.001,
                            "Width must fit in usable area for \(name)")
            assertCondition(layout.renderRectPixels.height <= layout.usableRectPixels.height + 0.001,
                            "Height must fit in usable area for \(name)")
            assertCondition(layout.renderRectPixels.minX >= layout.usableRectPixels.minX - 0.001,
                            "RenderX must not penetrate notch for \(name)")
        }

        print("  ✓ All 8 arbitrary resolutions preserve bit-for-bit aspect ratio with zero cropping or distortion.")
    }

    // MARK: - Test 7: Touch Coordinate Mapping Edge Precision
    static func test7_TouchCoordinateMappingEdgePrecision() {
        print("\n[Test 7] Touch-to-Video Coordinate Transformation Edge Precision...")
        let viewBounds = CGRect(x: 0, y: 0, width: 414, height: 896)
        let drawableSize = CGSize(width: 828, height: 1792)
        let insets = UIEdgeInsets(top: 48, left: 0, bottom: 34, right: 0)
        let videoSize = CGSize(width: 1170, height: 2532)

        let layout = RenderViewportLayout.compute(
            viewBounds: viewBounds,
            safeAreaInsets: insets,
            drawableSize: drawableSize,
            videoSize: videoSize,
            interfaceOrientation: .portrait
        )

        // Physical bottom edge touch (y = 896 pt): Must map exactly to y = 1.0
        let bottomTouch = CGPoint(x: viewBounds.midX, y: viewBounds.height)
        let normBottom = layout.touchToNormalizedVideoCoordinate(bottomTouch, clamp: true)
        assertCondition(normBottom != nil, "Bottom edge touch must produce normalized coordinate")
        assertCondition(abs(normBottom!.y - 1.0) < 0.001, "Bottom physical edge must map to y=1.0, got \(normBottom!.y)")

        // Top usable boundary touch (y = 48 pt, below notch): Must map to y = 0.0
        let topTouch = CGPoint(x: viewBounds.midX, y: 48.0)
        let normTop = layout.touchToNormalizedVideoCoordinate(topTouch, clamp: true)
        assertCondition(normTop != nil, "Top usable boundary touch must produce normalized coordinate")
        assertCondition(abs(normTop!.y - 0.0) < 0.001, "Top usable boundary must map to y=0.0, got \(normTop!.y)")

        // Center touch
        let centerTouch = CGPoint(x: layout.contentRectPoints.midX, y: layout.contentRectPoints.midY)
        let normCenter = layout.touchToNormalizedVideoCoordinate(centerTouch, clamp: false)
        assertCondition(normCenter != nil, "Center touch inside content rect")
        assertCondition(abs(normCenter!.x - 0.5) < 0.001, "Center X must map to 0.5")
        assertCondition(abs(normCenter!.y - 0.5) < 0.001, "Center Y must map to 0.5")

        // Out of bounds touch inside top notch (y = 10 pt) with clamp=false: Must be rejected (nil)
        let notchTouch = CGPoint(x: viewBounds.midX, y: 10.0)
        let normNotch = layout.touchToNormalizedVideoCoordinate(notchTouch, clamp: false)
        assertCondition(normNotch == nil, "Touch inside notch area must return nil when clamp is false")

        // Continuous drag clamp: Dragging into notch clamps to y = 0.0
        let normNotchClamped = layout.touchToNormalizedVideoCoordinate(notchTouch, clamp: true)
        assertCondition(normNotchClamped != nil && normNotchClamped!.y == 0.0,
                        "Dragging into notch must clamp safely to 0.0")

        print("  ✓ Touch coordinate mapping provides pixel-perfect normalization and edge accuracy.")
    }

    // MARK: - Test 8: iPad and No-Notch Edge-to-Edge Utilization
    static func test8_iPadAndNoNotchEdgeToEdge() {
        print("\n[Test 8] iPad & No-Notch Devices: 100% Screen Utilization...")
        // iPad 11-inch: 1194 x 834 pt, @2x -> 2388 x 1668 px
        // Safe area insets: bottom: 20 pt (home bar)
        let viewBounds = CGRect(x: 0, y: 0, width: 1194, height: 834)
        let drawableSize = CGSize(width: 2388, height: 1668)
        let insets = UIEdgeInsets(top: 0, left: 0, bottom: 20, right: 0)
        let videoSize = CGSize(width: 2388, height: 1668) // Exact matching resolution

        let layout = RenderViewportLayout.compute(
            viewBounds: viewBounds,
            safeAreaInsets: insets,
            drawableSize: drawableSize,
            videoSize: videoSize,
            interfaceOrientation: .landscapeLeft
        )

        assertCondition(layout.usableRectPixels.size == drawableSize, "Usable rect must cover entire iPad screen")
        assertCondition(layout.renderRectPixels.size == drawableSize, "Render rect must cover 100% of iPad screen")
        assertCondition(layout.renderRectPixels.origin == .zero, "Render rect must start at (0, 0)")
        print("  ✓ iPad display achieves 100% true full-screen utilization with zero artificial insets.")
    }

    // MARK: - Test 9: Dynamic Scale Factors (@1x, @2x, @3x)
    static func test9_DynamicScaleFactors_1x_2x_3x() {
        print("\n[Test 9] Dynamic Scale Factor Independence (@1x, @2x, @3x)...")
        let scales: [CGFloat] = [1.0, 2.0, 3.0]
        let basePoints = CGSize(width: 800, height: 400)
        let videoSize = CGSize(width: 1600, height: 800)

        for s in scales {
            let viewBounds = CGRect(origin: .zero, size: basePoints)
            let drawableSize = CGSize(width: basePoints.width * s, height: basePoints.height * s)
            let insets = UIEdgeInsets(top: 0, left: 30, bottom: 15, right: 0)

            let layout = RenderViewportLayout.compute(
                viewBounds: viewBounds,
                safeAreaInsets: insets,
                drawableSize: drawableSize,
                videoSize: videoSize,
                interfaceOrientation: .landscapeRight
            )

            assertCondition(abs(layout.scaleX - s) < 0.001, "scaleX must match \(s)")
            assertCondition(abs(layout.scaleY - s) < 0.001, "scaleY must match \(s)")
            assertCondition(abs(layout.renderRectPixels.width - (layout.contentRectPoints.width * s)) < 0.001,
                            "Pixel rect width must equal point rect * scale")
        }
        print("  ✓ Arbitrary scale factors (@1x, @2x, @3x) handled cleanly without floating drift.")
    }

    // MARK: - Test 10: Zero-Size Safety Guard
    static func test10_ZeroSizeSafety() {
        print("\n[Test 10] Zero-Size View / Video Bounds Guard...")
        let layout = RenderViewportLayout.compute(
            viewBounds: .zero,
            safeAreaInsets: .zero,
            drawableSize: .zero,
            videoSize: .zero
        )

        assertCondition(layout.renderRectPixels == .zero, "Zero input must produce zero render rect")
        assertCondition(layout.contentRectPoints == .zero, "Zero input must produce zero content rect")
        assertCondition(layout.touchToNormalizedVideoCoordinate(.zero) == nil, "Touch on zero layout returns nil")
        print("  ✓ Zero view/video geometry gracefully guarded with zero division immunity.")
    }
}

EdgeToEdgeTestSuite.runAll()
