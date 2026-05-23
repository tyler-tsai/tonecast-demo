#!/usr/bin/env swift
//
// render_icon.swift — generate Tonecast/Assets.xcassets/AppIcon.appiconset/icon-1024.png
//
// Design concept
// --------------
// Tonecast = voice + tone-shift + broadcast. The icon expresses this with
// three concentric arcs radiating outward from a small origin dot — sound
// emanating, "casting" to the world. A deep-indigo → warm-purple gradient
// background carries the brand color from the keyboard hero element. A
// small coral-red origin dot ties to the "recording" state color.
//
// Run from project root:
//   swift tools/render_icon.swift
//

import SwiftUI
import AppKit

// MARK: - Palette

private extension Color {
    static let bgTop      = Color(red: 0.30, green: 0.26, blue: 0.58)   // deep indigo
    static let bgBottom   = Color(red: 0.52, green: 0.32, blue: 0.66)   // warm purple
    static let arcStroke  = Color(red: 1.00, green: 0.98, blue: 0.96)   // warm cream
    static let originDot  = Color(red: 0.96, green: 0.36, blue: 0.40)   // coral red
}

// MARK: - Icon view

struct AppIcon: View {
    let size: CGFloat   // square edge length

    var body: some View {
        ZStack {
            // 1. Gradient background — diagonal so the icon catches light.
            LinearGradient(
                colors: [.bgTop, .bgBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // 2. Soft inner glow — very subtle radial light from origin.
            RadialGradient(
                colors: [
                    Color.white.opacity(0.18),
                    Color.white.opacity(0.0),
                ],
                center: UnitPoint(x: 0.38, y: 0.52),
                startRadius: 0,
                endRadius: size * 0.55
            )

            // 3. Three concentric arcs — the waveform / broadcast motif.
            //    Each arc opens to the right (sound radiating outward).
            //    Outer arcs are thinner + more transparent for depth.
            ForEach(0..<3, id: \.self) { i in
                let progress = CGFloat(i)
                Arc(
                    radiusFraction: 0.16 + progress * 0.12,
                    spanDegrees: 200 - progress * 12
                )
                .stroke(
                    Color.arcStroke.opacity(0.95 - progress * 0.22),
                    style: StrokeStyle(
                        lineWidth: max(28 - progress * 4, 14),
                        lineCap: .round
                    )
                )
                .frame(width: size, height: size)
            }

            // 4. Origin dot — the "voice source" — coral red accent.
            Circle()
                .fill(Color.originDot)
                .frame(width: size * 0.075, height: size * 0.075)
                .position(x: size * 0.38, y: size * 0.52)
                .shadow(color: Color.originDot.opacity(0.5),
                        radius: size * 0.02, x: 0, y: 0)
        }
        .frame(width: size, height: size)
    }
}

/// An arc centered at (0.38, 0.52) of the icon, opening to the right,
/// drawn as a horizontally-symmetric span (e.g. spanDegrees=200 means
/// 100° above and 100° below the +x axis).
private struct Arc: Shape {
    /// Radius as a fraction of the icon edge.
    let radiusFraction: CGFloat
    /// Angular span in degrees (centered on +x axis = pointing right).
    let spanDegrees: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let center = CGPoint(x: rect.width * 0.38, y: rect.height * 0.52)
        let r = rect.width * radiusFraction
        let half = spanDegrees / 2
        p.addArc(
            center: center,
            radius: r,
            startAngle: .degrees(-half),
            endAngle: .degrees(half),
            clockwise: false
        )
        return p
    }
}

// MARK: - Render to PNG

@MainActor
func renderIcon(edge: CGFloat, to url: URL) throws {
    let view = AppIcon(size: edge)
        .frame(width: edge, height: edge)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1   // we already specify pixel-perfect edge size
    renderer.isOpaque = true

    guard let nsImage = renderer.nsImage else {
        throw NSError(domain: "render_icon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "ImageRenderer returned nil"])
    }

    guard
        let tiff = nsImage.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .png, properties: [:])
    else {
        throw NSError(domain: "render_icon", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "PNG encode failed"])
    }

    try png.write(to: url)
}

// MARK: - Entry point

let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outPath = projectRoot
    .appendingPathComponent("Tonecast/Assets.xcassets/AppIcon.appiconset/icon-1024.png")

do {
    try MainActor.assumeIsolated {
        try renderIcon(edge: 1024, to: outPath)
    }
    print("✅ wrote \(outPath.path)")
} catch {
    print("❌ \(error.localizedDescription)")
    exit(1)
}
