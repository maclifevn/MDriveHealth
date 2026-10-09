/*
 * make_icon.swift — renders the MDriveHealth app icon (drive + pulse line)
 * and writes AppIcon.png (1024x1024). Run: swift scripts/make_icon.swift
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import AppKit

let canvas: CGFloat = 1024
let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()

// Big Sur-style rounded square with a deep blue→teal gradient.
let iconRect = NSRect(x: 100, y: 100, width: 824, height: 824)
let background = NSBezierPath(roundedRect: iconRect, xRadius: 184, yRadius: 184)
NSGradient(colors: [
    NSColor(calibratedRed: 0.04, green: 0.13, blue: 0.32, alpha: 1),
    NSColor(calibratedRed: 0.00, green: 0.42, blue: 0.50, alpha: 1),
])!.draw(in: background, angle: -70)

// Drive body: rounded slab in the lower half.
let drive = NSBezierPath(roundedRect: NSRect(x: 220, y: 240, width: 584, height: 320),
                         xRadius: 56, yRadius: 56)
NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
drive.fill()

// Drive detail: label slot + activity LED.
NSColor(calibratedWhite: 0.78, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 268, y: 448, width: 320, height: 44),
             xRadius: 22, yRadius: 22).fill()
NSColor(calibratedRed: 0.18, green: 0.8, blue: 0.44, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 716, y: 292, width: 40, height: 40)).fill()

// Heartbeat pulse across the drive.
let pulse = NSBezierPath()
pulse.lineWidth = 34
pulse.lineCapStyle = .round
pulse.lineJoinStyle = .round
pulse.move(to: NSPoint(x: 150, y: 640))
pulse.line(to: NSPoint(x: 380, y: 640))
pulse.line(to: NSPoint(x: 450, y: 780))
pulse.line(to: NSPoint(x: 550, y: 520))
pulse.line(to: NSPoint(x: 620, y: 640))
pulse.line(to: NSPoint(x: 874, y: 640))
NSColor(calibratedRed: 0.18, green: 0.86, blue: 0.50, alpha: 1).setStroke()
pulse.stroke()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
else {
    fatalError("failed to render icon")
}
let output = URL(fileURLWithPath: "scripts/AppIcon.png")
try! png.write(to: output)
print("wrote \(output.path)")
