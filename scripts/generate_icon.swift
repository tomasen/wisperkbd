#!/usr/bin/env swift
// Generates menu bar icons for WisperKbd from SF Symbols
import Cocoa

let size = NSSize(width: 18, height: 18)

func generateIcon(symbolName: String, outputPath: String, isTemplate: Bool = true, badge: Bool = false) {
    guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
        print("ERROR: Could not load SF Symbol '\(symbolName)'")
        exit(1)
    }

    let image = NSImage(size: size, flipped: false) { rect in
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        guard let configured = symbol.withSymbolConfiguration(config) else { return false }

        let symbolSize = configured.size
        let x = (rect.width - symbolSize.width) / 2
        let y = (rect.height - symbolSize.height) / 2
        configured.draw(in: NSRect(x: x, y: y, width: symbolSize.width, height: symbolSize.height))

        // Draw red recording dot
        if badge {
            let dotSize: CGFloat = 6
            let dotX = rect.width - dotSize - 0.5
            let dotY = rect.height - dotSize - 0.5
            NSColor.red.setFill()
            NSBezierPath(ovalIn: NSRect(x: dotX, y: dotY, width: dotSize, height: dotSize)).fill()
        }

        return true
    }

    image.isTemplate = isTemplate

    guard let tiffData = image.tiffRepresentation else {
        print("ERROR: Could not generate TIFF data")
        exit(1)
    }

    let url = URL(fileURLWithPath: outputPath)
    try! tiffData.write(to: url)
    print("Icon saved to \(outputPath)")
}

let resourceDir = "WisperKbd/Resources"

// Normal icon (template — adapts to light/dark mode)
generateIcon(symbolName: "mic.fill", outputPath: "\(resourceDir)/icon.tiff")

// Recording icon (non-template so the red dot shows in color)
generateIcon(symbolName: "mic.fill", outputPath: "\(resourceDir)/icon_recording.tiff", isTemplate: false, badge: true)
