// Icon-generation script for Reclaim — kept in the repo so the icon stays regenerable (see
// gokulmc/membar's scripts/render-icon.swift for the sibling script this mirrors; a prior
// project lost its render script with a temp dir, hence committing this one).
//
// Run:  swift scripts/render-icon.swift
// Produces (relative to the current working directory, so run it from the repo root):
//   Resources/AppIcon.icns   — the full icon set, ready for build.sh to copy into the bundle
//
// Design: a downward-returning arrow (the "space is coming back" motif — a return/enter-key
// shaped hook that lands on the drive) over a drive slab, on a blue -> teal squircle
// background, in the same flat, gradient-squircle style as gokulmc/membar's icon:
//   - squircle rect(0,0,100,100) r22.4, vertical gradient #1e40af (top) -> #0d9488 (bottom)
//   - top-half shine: white 26%->0% vertical gradient, height 42, same squircle clip
//   - white drive slab rect(15,64,70,22) r7
//   - drive groove: a rounded horizontal bar rect(25,72,40,6) r3 in a muted blue-gray
//   - drive activity LED: a small bright-teal circle at (74,75) r3.6
//   - white "return" arrow: horizontal hook from (72,22) to (30,22), curving down to
//     (30,54), capped with a downward-pointing triangular arrowhead landing on the slab
//
// IMPORTANT (same gotcha as membar's script): the 100pt master's coordinates are SVG-style
// (origin top-left, y grows downward). This script draws into an NSBitmapImageRep via a
// plain (non-flipped) NSGraphicsContext, where AppKit's origin is bottom-left and y grows
// upward — every rect/point's y must be converted with appKitY = masterHeight - svgY - height
// before scaling, or shapes end up vertically mirrored.

import AppKit

func makeBitmap(width: Int, height: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: width, height: height)
    return rep
}

func savePNG(_ rep: NSBitmapImageRep, to path: String) {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("Failed to encode PNG at \(path)")
    }
    do {
        try data.write(to: URL(fileURLWithPath: path))
    } catch {
        fatalError("Failed to write \(path): \(error)")
    }
}

// MARK: - Palette

let deepBlue = NSColor(calibratedRed: 0x1e / 255.0, green: 0x40 / 255.0, blue: 0xaf / 255.0, alpha: 1)
let teal = NSColor(calibratedRed: 0x0d / 255.0, green: 0x94 / 255.0, blue: 0x88 / 255.0, alpha: 1)
let tealBright = NSColor(calibratedRed: 0x2d / 255.0, green: 0xd4 / 255.0, blue: 0xbf / 255.0, alpha: 1)
let grooveBlue = NSColor(calibratedRed: 0x93 / 255.0, green: 0xb8 / 255.0, blue: 0xd6 / 255.0, alpha: 1)

/// Converts an SVG-space rect (origin top-left, y down) in the 100pt master into an
/// AppKit-space rect (origin bottom-left, y up) positioned relative to `canvas`, then scales
/// both position and size by `canvas.width / masterHeight`.
func convert(svgX: CGFloat, svgY: CGFloat, w: CGFloat, h: CGFloat, canvas: NSRect, masterHeight: CGFloat = 100) -> NSRect {
    let scale = canvas.width / masterHeight
    let appKitY = masterHeight - svgY - h
    return NSRect(x: canvas.minX + svgX * scale, y: canvas.minY + appKitY * scale, width: w * scale, height: h * scale)
}

/// Converts a single SVG-space point into AppKit space, same convention as `convert(svgX:...)`.
func convertPoint(svgX: CGFloat, svgY: CGFloat, canvas: NSRect, masterHeight: CGFloat = 100) -> NSPoint {
    let scale = canvas.width / masterHeight
    let appKitY = masterHeight - svgY
    return NSPoint(x: canvas.minX + svgX * scale, y: canvas.minY + appKitY * scale)
}

/// Draws the full icon into `canvas`, a square rect whose width is the render scale factor
/// applied to every 100pt-master coordinate above.
func drawIcon(in canvas: NSRect) {
    let scale = canvas.width / 100
    let cornerRadius = 22.4 * scale

    NSGraphicsContext.saveGraphicsState()
    let squircle = NSBezierPath(roundedRect: canvas, xRadius: cornerRadius, yRadius: cornerRadius)
    squircle.addClip()

    // Vertical gradient, deep blue at the SVG top -> teal at the SVG bottom. angle 90 places
    // the gradient's first color at the rect's bottom, second at the top (AppKit convention),
    // so first=teal (SVG bottom), second=deepBlue (SVG top) gives the correct direction.
    let bgGradient = NSGradient(starting: teal, ending: deepBlue)!
    bgGradient.draw(in: canvas, angle: 90)

    // Top-half shine.
    let shineRect = convert(svgX: 0, svgY: 0, w: 100, h: 42, canvas: canvas)
    let shineGradient = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0),
        NSColor.white.withAlphaComponent(0.26),
    ])!
    shineGradient.draw(in: shineRect, angle: 90)

    // White drive slab.
    let slabRect = convert(svgX: 15, svgY: 64, w: 70, h: 22, canvas: canvas)
    let slabPath = NSBezierPath(roundedRect: slabRect, xRadius: 7 * scale, yRadius: 7 * scale)
    NSColor.white.setFill()
    slabPath.fill()

    // Drive groove (a muted horizontal bar suggesting a vent/slot).
    let grooveRect = convert(svgX: 25, svgY: 72, w: 40, h: 6, canvas: canvas)
    let groovePath = NSBezierPath(roundedRect: grooveRect, xRadius: 3 * scale, yRadius: 3 * scale)
    grooveBlue.setFill()
    groovePath.fill()

    // Drive activity LED.
    let ledCenter = convertPoint(svgX: 74, svgY: 75, canvas: canvas)
    let ledRadius = 3.6 * scale
    let ledRect = NSRect(x: ledCenter.x - ledRadius, y: ledCenter.y - ledRadius, width: ledRadius * 2, height: ledRadius * 2)
    tealBright.setFill()
    NSBezierPath(ovalIn: ledRect).fill()

    // White "return" arrow: a rounded hook from the top-right, curving down, landing on the
    // slab as a downward-pointing arrowhead — the "space is coming back" motif.
    let hook = NSBezierPath()
    hook.lineWidth = 9 * scale
    hook.lineCapStyle = .round
    hook.lineJoinStyle = .round

    let hookStart = convertPoint(svgX: 72, svgY: 22, canvas: canvas)
    let cornerStart = convertPoint(svgX: 38, svgY: 22, canvas: canvas)
    let cornerControl = convertPoint(svgX: 30, svgY: 22, canvas: canvas)
    let cornerEnd = convertPoint(svgX: 30, svgY: 30, canvas: canvas)
    let hookEnd = convertPoint(svgX: 30, svgY: 53, canvas: canvas)

    hook.move(to: hookStart)
    hook.line(to: cornerStart)
    hook.curve(to: cornerEnd, controlPoint1: cornerControl, controlPoint2: cornerControl)
    hook.line(to: hookEnd)
    NSColor.white.setStroke()
    hook.stroke()

    // Arrowhead: a filled triangle whose tip touches down into the top of the drive slab.
    let arrowLeft = convertPoint(svgX: 19, svgY: 54, canvas: canvas)
    let arrowRight = convertPoint(svgX: 41, svgY: 54, canvas: canvas)
    let arrowTip = convertPoint(svgX: 30, svgY: 67, canvas: canvas)
    let arrowhead = NSBezierPath()
    arrowhead.move(to: arrowLeft)
    arrowhead.line(to: arrowRight)
    arrowhead.line(to: arrowTip)
    arrowhead.close()
    NSColor.white.setFill()
    arrowhead.fill()

    NSGraphicsContext.restoreGraphicsState()
}

func renderPNG(size: Int, to path: String) {
    let rep = makeBitmap(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    savePNG(rep, to: path)
}

// MARK: - Build the .iconset and convert to .icns

let fm = FileManager.default
let repoRoot = fm.currentDirectoryPath
let resourcesDir = repoRoot + "/Resources"
let iconsetDir = NSTemporaryDirectory() + "reclaim-icon-\(UUID().uuidString).iconset"

try? fm.createDirectory(atPath: resourcesDir, withIntermediateDirectories: true)
try! fm.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

// Required members of a .iconset for `iconutil -c icns` (base size, @2x variant, or both).
let iconsetSizes: [(name: String, size: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for entry in iconsetSizes {
    renderPNG(size: entry.size, to: iconsetDir + "/" + entry.name)
}

print("Wrote iconset to \(iconsetDir)")

let icnsPath = resourcesDir + "/AppIcon.icns"
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetDir, "-o", icnsPath]
try! process.run()
process.waitUntilExit()

try? fm.removeItem(atPath: iconsetDir)

if process.terminationStatus == 0 {
    print("Wrote \(icnsPath)")
} else {
    fatalError("iconutil exited with status \(process.terminationStatus)")
}
