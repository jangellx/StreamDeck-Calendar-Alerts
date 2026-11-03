import AppKit
import CoreGraphics
import ImageIO

// Renders 72×72 button images for the StreamDeck hardware.
// Uses a CGContext backed by NSGraphicsContext so NSAttributedString handles
// text wrapping and emoji font fallback without requiring NSApplication.
final class ButtonImageRenderer {
    static let shared = ButtonImageRenderer()
    private let size = 72

    private init() {}

    // flashPhase is only meaningful when minutesUntil == 0:
    //   false → no strip, red "Now!" text
    //   true  → red strip, black "Now!" text
    func renderEvent(title: String, minutesUntil: Int, flashPhase: Bool = false) -> String {
        guard let ctx = makeContext() else { return "" }

        // Background always near-black.
        ctx.setFillColor(CGColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

        // y=0 is at the bottom in CG coordinates. The strip covers the time label area.
        let stripRect = CGRect(x: 0, y: 0, width: size, height: 23)
        let timeColor: NSColor

        if minutesUntil == 0 {
            if flashPhase {
                ctx.setFillColor(CGColor(red: 0.90, green: 0.15, blue: 0.15, alpha: 1))
                ctx.fill(stripRect)
                timeColor = .black
            } else {
                timeColor = NSColor(red: 0.90, green: 0.15, blue: 0.15, alpha: 1.0)
            }
        } else if let strip = stripColorFor(minutes: minutesUntil) {
            // <60 min: colored strip, black text for contrast.
            ctx.setFillColor(strip)
            ctx.fill(stripRect)
            timeColor = .black
        } else {
            // ≥60 min: no strip, white text.
            timeColor = .white
        }

        withNSGraphicsContext(ctx) {
            // Lower area: time remaining, centered, larger font.
            draw(formatTime(minutesUntil),
                 font: .boldSystemFont(ofSize: 15),
                 color: timeColor,
                 alignment: .center,
                 in: CGRect(x: 4, y: 2, width: 64, height: 18))

            // Upper area: event title, white, left-aligned, wraps up to ~3 lines.
            draw(cleanTitle(title),
                 font: .boldSystemFont(ofSize: 11),
                 color: .white,
                 alignment: .left,
                 in: CGRect(x: 4, y: 24, width: 64, height: 44))
        }

        return toPNGDataURI(ctx)
    }

    func renderNoMeetings() -> String {
        // Load the smiley calendar image from the plugin bundle's Images folder.
        let execDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let imageURL = execDir.appendingPathComponent("Images/no-meetings.png")
        if let data = try? Data(contentsOf: imageURL) {
            return "data:image/png;base64," + data.base64EncodedString()
        }

        // Fallback: generated image if file is missing.
        guard let ctx = makeContext() else { return "" }
        ctx.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        withNSGraphicsContext(ctx) {
            draw("📅", font: .systemFont(ofSize: 34), color: .white, alignment: .center,
                 in: CGRect(x: 0, y: 20, width: 72, height: 44))
        }
        return toPNGDataURI(ctx)
    }

    // MARK: - Private

    private func makeContext() -> CGContext? {
        CGContext(data: nil, width: size, height: size,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                              CGBitmapInfo.byteOrder32Little.rawValue)
    }

    // Wraps the CGContext in an NSGraphicsContext using standard CG coordinates (y=0 at bottom).
    private func withNSGraphicsContext(_ cgCtx: CGContext, _ block: () -> Void) {
        let nsCtx = NSGraphicsContext(cgContext: cgCtx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        block()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func draw(_ text: String, font: NSFont, color: NSColor, alignment: NSTextAlignment, in rect: CGRect) {
        let para = NSMutableParagraphStyle()
        para.alignment = alignment
        para.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: para
        ]
        NSAttributedString(string: text, attributes: attrs).draw(in: rect)
    }

    // Returns a strip color for 1–59 min, nil for ≥60 min (no strip) and 0 (handled separately).
    private func stripColorFor(minutes: Int) -> CGColor? {
        switch minutes {
        case 1..<6:   return CGColor(red: 0.90, green: 0.15, blue: 0.15, alpha: 1) // red
        case 6..<11:  return CGColor(red: 0.95, green: 0.50, blue: 0.10, alpha: 1) // orange
        case 11..<16: return CGColor(red: 0.80, green: 0.72, blue: 0.05, alpha: 1) // yellow
        case 16..<31: return CGColor(red: 0.10, green: 0.35, blue: 0.85, alpha: 1) // blue
        case 31..<60: return CGColor(red: 0.40, green: 0.70, blue: 1.00, alpha: 1) // light blue
        default:      return nil
        }
    }

    private func formatTime(_ minutes: Int) -> String {
        guard minutes > 0 else { return "NOW" }
        if minutes >= 60 {
            let h = minutes / 60
            let m = minutes % 60
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        return "\(minutes)m"
    }

    // Strip leading numeric room/floor codes, e.g. "101 " from "101 Team Standup".
    private func cleanTitle(_ title: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"^[\d\s\-\.]+"#),
              let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              match.range.length > 0 && match.range.length < title.count else { return title }
        let idx = title.index(title.startIndex, offsetBy: match.range.length)
        let cleaned = String(title[idx...]).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? title : cleaned
    }

    private func toPNGDataURI(_ ctx: CGContext) -> String {
        guard let image = ctx.makeImage() else { return "" }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else { return "" }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return "" }
        return "data:image/png;base64," + (data as Data).base64EncodedString()
    }
}
