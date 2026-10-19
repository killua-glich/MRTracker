// Renders the GitLab MR Tracker app icon into MyAppSources/Assets.xcassets/AppIcon.appiconset.
//
// Run from the repo's gitlab-mr-tracker folder:  swift Design/make_app_icon.swift
//
// Artwork: a merge graph (a branch curving into a main line) in white on an indigo
// gradient, with the merge node drawn as the app's green "ready to merge" dot. Drawn as
// a full-bleed square — macOS applies the rounded mask and Liquid Glass effects itself.
// No SF Symbols (their license doesn't allow use in app icons).

import AppKit

let outputDir = URL(fileURLWithPath: "MyAppSources/Assets.xcassets/AppIcon.appiconset")

func renderMaster(size: CGFloat = 1024) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.displayP3)!
    let ctx = CGContext(
        data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let s = size / 1024 // all geometry below is authored on a 1024 canvas, y up

    // Background: indigo diagonal gradient, full bleed.
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(colorSpace: space, components: [0.38, 0.40, 0.98, 1])!,
            CGColor(colorSpace: space, components: [0.15, 0.13, 0.42, 1])!,
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: []
    )

    let white = CGColor(colorSpace: space, components: [1, 1, 1, 1])!
    let green = CGColor(colorSpace: space, components: [0.20, 0.82, 0.38, 1])!

    let mainX: CGFloat = 610 * s
    let branchX: CGFloat = 400 * s
    let bottomNode = CGPoint(x: mainX, y: 250 * s)
    let mergeNode = CGPoint(x: mainX, y: 770 * s)
    let branchNode = CGPoint(x: branchX, y: 340 * s)

    // Lines: main trunk + branch curving into it just below the merge node.
    ctx.setStrokeColor(white)
    ctx.setLineWidth(58 * s)
    ctx.setLineCap(.round)

    ctx.move(to: bottomNode)
    ctx.addLine(to: mergeNode)
    ctx.strokePath()

    ctx.move(to: branchNode)
    ctx.addLine(to: CGPoint(x: branchX, y: 470 * s))
    ctx.addCurve(
        to: CGPoint(x: mainX, y: 690 * s),
        control1: CGPoint(x: branchX, y: 600 * s),
        control2: CGPoint(x: mainX, y: 560 * s)
    )
    ctx.strokePath()

    // Commit nodes.
    func node(_ center: CGPoint, radius: CGFloat, color: CGColor) {
        ctx.setFillColor(color)
        ctx.fillEllipse(in: CGRect(
            x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2
        ))
    }
    node(bottomNode, radius: 66 * s, color: white)
    node(branchNode, radius: 66 * s, color: white)

    // Merge node: the "ready to merge" dot, with a soft glow like the popup's ReadyDot.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 70 * s,
                  color: CGColor(colorSpace: space, components: [0.20, 0.82, 0.38, 0.85])!)
    node(mergeNode, radius: 84 * s, color: green)
    ctx.restoreGState()
    // Thin white ring separates the green node from the white trunk it sits on.
    ctx.setStrokeColor(white)
    ctx.setLineWidth(18 * s)
    ctx.strokeEllipse(in: CGRect(
        x: mergeNode.x - 84 * s, y: mergeNode.y - 84 * s, width: 168 * s, height: 168 * s
    ))

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, pixels: Int, to url: URL) throws {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    gc.imageInterpolation = .high
    NSGraphicsContext.current = gc
    gc.cgContext.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

// macOS app icon slots: (point size, scale).
let slots: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                           (256, 1), (256, 2), (512, 1), (512, 2)]

try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
let master = renderMaster()
var images: [[String: String]] = []
for (points, scale) in slots {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try writePNG(master, pixels: points * scale, to: outputDir.appendingPathComponent(name))
    images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
}

let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: outputDir.appendingPathComponent("Contents.json"))
try #"{"info":{"author":"xcode","version":1}}"#.data(using: .utf8)!
    .write(to: outputDir.deletingLastPathComponent().appendingPathComponent("Contents.json"))
print("Wrote \(slots.count) icons to \(outputDir.path)")
