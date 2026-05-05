#!/usr/bin/env swift
// scripts/generate_app_icon.swift
//
// Generates the Cool Tunnel macOS app icon stack from a single
// programmatic master at 1024×1024.
//
// Usage:
//
//   swift scripts/generate_app_icon.swift COOL-TUNNEL/Assets.xcassets/AppIcon.appiconset
//
// Produces every PNG referenced by the AppIcon.appiconset's
// Contents.json, at the right pixel size for each (idiom, scale)
// combination. The 1024 master is rendered with CoreGraphics; all
// smaller sizes are NSImage-resized with `.high` interpolation.
//
// Design (Phase 2.2 visual identity):
//
//   - Squircle backdrop, cool-blue diagonal gradient (top-left
//     lighter, bottom-right deeper). Reads as the "Cool" half.
//   - Three concentric stroked rings forming a tunnel cross-
//     section. Each subsequent ring is smaller and shifted
//     upward-right, producing a one-point perspective: the user
//     is looking *through* a tunnel, not *at* a target. Reads as
//     the "Tunnel" half.
//   - A bright radial highlight at the vanishing point — the
//     "light at the end of the tunnel" cue.
//   - Subtle inner-shadow fill on the squircle and a soft outer
//     drop shadow for depth, matching Apple's macOS icon idiom.
//
// This is a programmatic icon, not a designer-painted one. It
// reads as a Mac app icon at every system size; for a final
// editorial-quality icon, replace the master rendering below
// with a hand-crafted 1024 PNG.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Design constants

private let MASTER_PX: CGFloat = 1024
/// Apple's macOS Big Sur+ icon corner radius is ≈22.37 % of the
/// icon side. Standard `cornerRadius` is a close-enough proxy
/// for the platonic squircle (the perceptual difference is sub-
/// pixel below 256 px).
private let CORNER_RATIO: CGFloat = 0.2237
/// Inset between the canvas edge and the squircle so there's
/// breathing room for a soft drop shadow without clipping.
private let INSET: CGFloat = 36

// MARK: - Master render

private func renderMaster() -> NSImage {
    let size = NSSize(width: MASTER_PX, height: MASTER_PX)
    return NSImage(size: size, flipped: false) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        let s = MASTER_PX
        let inset = INSET

        // Squircle frame and rounded path.
        let squircleRect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
        let cornerRadius = squircleRect.width * CORNER_RATIO
        let squirclePath = CGPath(
            roundedRect: squircleRect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )

        // 1. Soft outer drop shadow (under the squircle).
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -8),
            blur: 24,
            color: NSColor.black.withAlphaComponent(0.30).cgColor
        )
        ctx.addPath(squirclePath)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        // 2. Squircle backdrop with diagonal gradient.
        ctx.saveGState()
        ctx.addPath(squirclePath)
        ctx.clip()

        let topColor = NSColor(red: 0.36, green: 0.55, blue: 0.95, alpha: 1.0)
        let bottomColor = NSColor(red: 0.13, green: 0.24, blue: 0.62, alpha: 1.0)
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [topColor.cgColor, bottomColor.cgColor] as CFArray,
            locations: [0.0, 1.0]
        )!
        // Top-left → bottom-right diagonal. Conventional macOS
        // icon lighting comes from upper-right; the gradient
        // direction suggests a soft top-down light source.
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: squircleRect.minX, y: squircleRect.maxY),
            end: CGPoint(x: squircleRect.maxX, y: squircleRect.minY),
            options: []
        )
        ctx.restoreGState()

        // 3. Inner highlight — narrow band of brighter color
        // along the top edge, simulating ambient light catching
        // the edge of the squircle. Painted INSIDE the clip.
        ctx.saveGState()
        ctx.addPath(squirclePath)
        ctx.clip()
        let highlight = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                NSColor.white.withAlphaComponent(0.18).cgColor,
                NSColor.white.withAlphaComponent(0.0).cgColor,
            ] as CFArray,
            locations: [0.0, 1.0]
        )!
        ctx.drawLinearGradient(
            highlight,
            start: CGPoint(x: squircleRect.midX, y: squircleRect.maxY),
            end: CGPoint(x: squircleRect.midX, y: squircleRect.midY),
            options: []
        )
        ctx.restoreGState()

        // 4. Concentric tunnel rings.
        // Each ring is smaller and offset upper-right from the
        // previous, producing a one-point perspective vanishing
        // toward (cx + dx, cy + dy). The viewer reads "looking
        // through a tunnel" rather than "target/bullseye" because
        // the rings are decentered.
        //
        // **Phase 2.2 contrast pass:** the original 4-ring scheme
        // dissolved to invisible noise at 32 px. Reduced to 3
        // rings, alphas pushed to 0.55 / 0.78 / 0.95, strokes
        // thickened proportionally so the tunnel motif survives
        // a 32× downsample.
        let cx = squircleRect.midX
        let cy = squircleRect.midY
        let baseRadius = squircleRect.width * 0.40

        struct Ring { let radius: CGFloat; let lineWidth: CGFloat; let alpha: CGFloat; let dx: CGFloat; let dy: CGFloat }
        let rings: [Ring] = [
            Ring(radius: baseRadius * 1.00, lineWidth: 28, alpha: 0.55, dx: 0,  dy: 0),
            Ring(radius: baseRadius * 0.66, lineWidth: 24, alpha: 0.78, dx: 18, dy: 24),
            Ring(radius: baseRadius * 0.36, lineWidth: 20, alpha: 0.95, dx: 36, dy: 48),
        ]

        for ring in rings {
            ctx.saveGState()
            ctx.setShadow(
                offset: CGSize(width: 0, height: -4),
                blur: 12,
                color: NSColor.black.withAlphaComponent(0.30).cgColor
            )
            let center = CGPoint(x: cx + ring.dx, y: cy + ring.dy)
            let rect = CGRect(
                x: center.x - ring.radius,
                y: center.y - ring.radius,
                width: ring.radius * 2,
                height: ring.radius * 2
            )
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(ring.alpha).cgColor)
            ctx.setLineWidth(ring.lineWidth)
            ctx.strokeEllipse(in: rect)
            ctx.restoreGState()
        }

        // 5. Bright vanishing-point highlight — radial gradient
        // at the innermost ring's center. Reads as "light at
        // the end of the tunnel."
        // Phase 2.2: enlarged + softer falloff so this stays
        // visible at 16 px (where it's the only motif that
        // survives the resample) without blowing out at 1024.
        ctx.saveGState()
        let lastRing = rings.last!
        let spotCenter = CGPoint(x: cx + lastRing.dx, y: cy + lastRing.dy)
        let spotGradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                NSColor.white.withAlphaComponent(0.98).cgColor,
                NSColor(red: 0.78, green: 0.88, blue: 1.0, alpha: 0.55).cgColor,
                NSColor.white.withAlphaComponent(0.0).cgColor,
            ] as CFArray,
            locations: [0.0, 0.45, 1.0]
        )!
        ctx.drawRadialGradient(
            spotGradient,
            startCenter: spotCenter,
            startRadius: 0,
            endCenter: spotCenter,
            endRadius: lastRing.radius * 1.4,
            options: []
        )
        ctx.restoreGState()

        return true
    }
}

// MARK: - Resize

private func resize(_ source: NSImage, to pixelSize: CGFloat) -> NSImage {
    let size = NSSize(width: pixelSize, height: pixelSize)
    let result = NSImage(size: size, flipped: false) { rect in
        let context = NSGraphicsContext.current
        context?.imageInterpolation = .high
        source.draw(
            in: rect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        return true
    }
    return result
}

// MARK: - PNG export

private func writePNG(_ image: NSImage, pixelSize: CGFloat, to url: URL) throws {
    // Build the rep at the *exact* target pixel size so the PNG
    // metadata matches what the asset catalog expects (Xcode
    // rejects mismatched dimensions for an explicit-pixel-size
    // entry).
    let pixels = Int(pixelSize)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 32
    ) else {
        throw NSError(domain: "icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not create NSBitmapImageRep"])
    }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: .zero,
        operation: .sourceOver,
        fraction: 1.0
    )
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "PNG encode failed"])
    }
    try png.write(to: url)
}

// MARK: - Main

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(
        "usage: \(CommandLine.arguments[0]) <AppIcon.appiconset path>\n".data(using: .utf8)!
    )
    exit(64)
}

let outputDir = URL(fileURLWithPath: CommandLine.arguments[1])

let master = renderMaster()

// (filename, target pixel size)
let outputs: [(String, CGFloat)] = [
    // macOS idiom
    ("Icon-16.png",       16),    // 16×16 @1x
    ("Icon-32.png",       32),    // 16×16 @2x
    ("Icon-32-1x.png",    32),    // 32×32 @1x
    ("Icon-64.png",       64),    // 32×32 @2x
    ("Icon-128.png",     128),    // 128×128 @1x
    ("Icon-256.png",     256),    // 128×128 @2x
    ("Icon-256-1x.png",  256),    // 256×256 @1x
    ("Icon-512.png",     512),    // 256×256 @2x
    ("Icon-512-1x.png",  512),    // 512×512 @1x
    ("Icon-1024-mac.png", 1024),  // 512×512 @2x

    // iOS idiom (universal). We re-emit the same master for
    // all three appearance variants — the macOS app doesn't
    // run on iOS so a minimal placeholder is fine here.
    ("Icon-1024.png",         1024),
    ("Icon-1024-dark.png",    1024),
    ("Icon-1024-tinted.png",  1024),
]

for (filename, pixelSize) in outputs {
    let url = outputDir.appendingPathComponent(filename)
    try writePNG(master, pixelSize: pixelSize, to: url)
    print("✓ \(filename) (\(Int(pixelSize))×\(Int(pixelSize)))")
}

print("done.")
