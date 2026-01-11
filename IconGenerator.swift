#!/usr/bin/env swift

import Cocoa
import Foundation

// Create a modern DAW icon with waveform and gradient
func createDAWIcon(size: Int) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    
    image.lockFocus()
    
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let cornerRadius = CGFloat(size) * 0.22 // macOS Big Sur style rounded corners
    
    // Create rounded rect path
    let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    
    // Create gradient background - deep purple to vibrant blue
    let gradient = NSGradient(colors: [
        NSColor(red: 0.15, green: 0.05, blue: 0.25, alpha: 1.0),  // Deep purple
        NSColor(red: 0.1, green: 0.1, blue: 0.35, alpha: 1.0),   // Dark blue
        NSColor(red: 0.2, green: 0.1, blue: 0.4, alpha: 1.0),    // Purple
    ], atLocations: [0.0, 0.5, 1.0], colorSpace: .deviceRGB)!
    
    path.addClip()
    gradient.draw(in: rect, angle: -45)
    
    // Draw waveform
    let waveformColor = NSColor(red: 0.4, green: 0.8, blue: 1.0, alpha: 0.9) // Cyan
    let waveformGlow = NSColor(red: 0.4, green: 0.8, blue: 1.0, alpha: 0.3)
    
    let centerY = CGFloat(size) / 2
    let waveHeight = CGFloat(size) * 0.35
    let margin = CGFloat(size) * 0.15
    let waveWidth = CGFloat(size) - margin * 2
    
    // Draw glow behind waveform
    let glowPath = NSBezierPath()
    glowPath.lineWidth = CGFloat(size) * 0.08
    glowPath.lineCapStyle = .round
    
    let numBars = 24
    let barWidth = waveWidth / CGFloat(numBars)
    
    for i in 0..<numBars {
        let x = margin + CGFloat(i) * barWidth + barWidth / 2
        
        // Create a musical waveform pattern
        let progress = CGFloat(i) / CGFloat(numBars - 1)
        let wave1 = sin(progress * .pi * 3) * 0.5
        let wave2 = sin(progress * .pi * 5 + 0.5) * 0.3
        let envelope = sin(progress * .pi) // Fade in/out
        let height = (0.3 + abs(wave1 + wave2) * 0.7) * envelope * waveHeight
        
        glowPath.move(to: NSPoint(x: x, y: centerY - height))
        glowPath.line(to: NSPoint(x: x, y: centerY + height))
    }
    
    waveformGlow.setStroke()
    glowPath.stroke()
    
    // Draw main waveform bars
    let wavePath = NSBezierPath()
    wavePath.lineWidth = CGFloat(size) * 0.035
    wavePath.lineCapStyle = .round
    
    for i in 0..<numBars {
        let x = margin + CGFloat(i) * barWidth + barWidth / 2
        
        let progress = CGFloat(i) / CGFloat(numBars - 1)
        let wave1 = sin(progress * .pi * 3) * 0.5
        let wave2 = sin(progress * .pi * 5 + 0.5) * 0.3
        let envelope = sin(progress * .pi)
        let height = (0.3 + abs(wave1 + wave2) * 0.7) * envelope * waveHeight
        
        wavePath.move(to: NSPoint(x: x, y: centerY - height))
        wavePath.line(to: NSPoint(x: x, y: centerY + height))
    }
    
    waveformColor.setStroke()
    wavePath.stroke()
    
    // Draw playhead line
    let playheadX = margin + waveWidth * 0.35
    let playheadPath = NSBezierPath()
    playheadPath.move(to: NSPoint(x: playheadX, y: CGFloat(size) * 0.2))
    playheadPath.line(to: NSPoint(x: playheadX, y: CGFloat(size) * 0.8))
    playheadPath.lineWidth = CGFloat(size) * 0.015
    
    NSColor(red: 1.0, green: 0.3, blue: 0.4, alpha: 0.9).setStroke()
    playheadPath.stroke()
    
    // Draw playhead triangle
    let triangleSize = CGFloat(size) * 0.06
    let trianglePath = NSBezierPath()
    trianglePath.move(to: NSPoint(x: playheadX - triangleSize/2, y: CGFloat(size) * 0.8))
    trianglePath.line(to: NSPoint(x: playheadX + triangleSize/2, y: CGFloat(size) * 0.8))
    trianglePath.line(to: NSPoint(x: playheadX, y: CGFloat(size) * 0.8 - triangleSize))
    trianglePath.close()
    
    NSColor(red: 1.0, green: 0.3, blue: 0.4, alpha: 1.0).setFill()
    trianglePath.fill()
    
    // Add subtle inner shadow/border
    let borderPath = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
    borderPath.lineWidth = 1
    NSColor(white: 1.0, alpha: 0.1).setStroke()
    borderPath.stroke()
    
    image.unlockFocus()
    
    return image
}

// Generate iconset
func createIconset() {
    let iconsetPath = "/tmp/AppIcon.iconset"
    let fm = FileManager.default
    
    // Remove existing iconset
    try? fm.removeItem(atPath: iconsetPath)
    try! fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)
    
    // Icon sizes needed for macOS
    let sizes: [(Int, String)] = [
        (16, "icon_16x16.png"),
        (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"),
        (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"),
        (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"),
        (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"),
        (1024, "icon_512x512@2x.png"),
    ]
    
    for (size, filename) in sizes {
        let icon = createDAWIcon(size: size)
        let url = URL(fileURLWithPath: iconsetPath).appendingPathComponent(filename)
        
        if let tiffData = icon.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            try! pngData.write(to: url)
            print("Created \(filename)")
        }
    }
    
    print("\nIconset created at \(iconsetPath)")
    print("Converting to .icns...")
}

// Run
createIconset()
print("Done!")
