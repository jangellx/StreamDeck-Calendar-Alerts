import AppKit
import CoreGraphics
import ImageIO

// Renders key images for the Stream Deck hardware, plus the plugin's icon artwork.
// Uses a CGContext backed by NSGraphicsContext so NSAttributedString handles
// text wrapping and emoji font fallback without requiring NSApplication.
// Bundled key images in Images/ come from Joe Angell's Perpetual app icons;
// see Tools/make-images.sh.
final class ButtonImageRenderer {
    // Keys are laid out in 72×72 points and rendered at 2× (144×144 px), which
    // Stream Deck scales down to each device's key size.
    static let shared = ButtonImageRenderer(scale: 2)

    private let size: CGFloat = 72
    private let scale: CGFloat
    private let imagesDirectory: URL
    private var cachedImages: [String: String] = [:]

    // imagesDirectory holds the bundled key images (the plugin's Images folder).
    init(scale: CGFloat,
         imagesDirectory: URL = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().appendingPathComponent("Images")) {
        self.scale = scale
        self.imagesDirectory = imagesDirectory
    }

    // flashPhase is only meaningful when minutesUntil == 0:
    //   false → no strip, red "NOW" text
    //   true  → red strip, black "NOW" text
    // A reminder is drawn like an event, with Reminders' open circle before its title.
    func renderEvent(title: String, minutesUntil: Int, flashPhase: Bool = false, reminder: Bool = false) -> String {
        guard let ctx = makeKeyContext() else { return "" }
        Self.fillKeyBackground(ctx, size: size)

        // y=0 is at the bottom in CG coordinates. The strip covers the time label area.
        let stripRect = CGRect(x: 0, y: 0, width: size, height: 23)
        let timeColor: NSColor

        if minutesUntil == 0 {
            if flashPhase {
                ctx.setFillColor(Palette.red)
                ctx.fill(stripRect)
                timeColor = .black
            } else {
                timeColor = NSColor(cgColor: Palette.red) ?? .red
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
            draw(keyTitle(title, reminder: reminder),
                 font: .boldSystemFont(ofSize: 11),
                 color: .white,
                 alignment: .left,
                 in: CGRect(x: 4, y: 24, width: 64, height: 44))
        }

        return toPNGDataURI(ctx)
    }

    // An all-day event, shown when no timed event is left today: the title as
    // for a timed event, with "All day" in place of the countdown. `others` is
    // how many more all-day items there are today ("All day +2"). Reminders say
    // "Today", or "Overdue" when their time has passed.
    func renderAllDay(title: String, others: Int = 0, label: String = "All day", reminder: Bool = false) -> String {
        guard let ctx = makeKeyContext() else { return "" }
        Self.fillKeyBackground(ctx, size: size)
        withNSGraphicsContext(ctx) {
            draw(others > 0 ? "\(label) +\(others)" : label,
                 font: .boldSystemFont(ofSize: 13),
                 color: NSColor(white: 0.62, alpha: 1),
                 alignment: .center,
                 in: CGRect(x: 2, y: 3, width: 68, height: 18))
            draw(keyTitle(title, reminder: reminder),
                 font: .boldSystemFont(ofSize: 11),
                 color: .white,
                 alignment: .left,
                 in: CGRect(x: 4, y: 24, width: 64, height: 44))
        }
        return toPNGDataURI(ctx)
    }

    // A reminder just marked done from the key: checked off, on a green strip.
    // Holding or double-tapping again while it shows marks it not done.
    func renderReminderDone(title: String) -> String {
        guard let ctx = makeKeyContext() else { return "" }
        Self.fillKeyBackground(ctx, size: size)
        ctx.setFillColor(Palette.green)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: 23))
        withNSGraphicsContext(ctx) {
            draw("Done", font: .boldSystemFont(ofSize: 15), color: .black, alignment: .center,
                 in: CGRect(x: 4, y: 2, width: 64, height: 18))
            draw("✓ " + cleanTitle(title), font: .boldSystemFont(ofSize: 11),
                 color: NSColor(white: 0.62, alpha: 1), alignment: .left,
                 in: CGRect(x: 4, y: 24, width: 64, height: 44))
        }
        return toPNGDataURI(ctx)
    }

    // What the key shows when there are no more events today. Styles:
    //   "smile"      – the bundled smiling calendar, light version
    //   "smile-dark" – the same, dark version
    //   "loop"       – the bundled infinity-and-ticks icon (Perpetual's ClockLoop), light version
    //   "loop-dark"  – the same, dark version
    //   "check"      – a drawn red calendar with a white checkmark and "All clear"
    //   "check-emoji" – a checkmark emoji
    //   "moon"       – today's moon phase (NASA images, bundled; see MoonPhase) (default)
    //   "crescent"   – a crescent moon emoji
    //   "thumbs"     – a thumbs-up emoji
    //   "text"       – the words "No more events today"
    //   "message"    – the user's own words, passed in as customMessage
    //   "custom"     – the user's own image, passed in as a data: URL
    static let defaultNoEventsText = "No more events today"

    func renderNoEvents(style: String, customImage: String = "", customMessage: String = "") -> String {
        switch style {
        case "custom" where customImage.hasPrefix("data:image/"):
            return customImage
        case "message":
            let message = customMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            return renderMessage(message.isEmpty ? Self.defaultNoEventsText : message)
        case "check":
            return renderAllClear()
        case "check-emoji":
            return renderEmoji("✅")
        case "thumbs":
            return renderEmoji("👍")
        case "text":
            return renderMessage(Self.defaultNoEventsText)
        case "smile-dark":
            return bundledImage("no-events-dark") ?? renderAllClear()
        case "crescent":
            return renderEmoji("🌙")
        case "smile":
            return bundledImage("no-events-light") ?? renderAllClear()
        case "loop":
            return bundledImage("no-events-loop-light") ?? renderAllClear()
        case "loop-dark":
            return bundledImage("no-events-loop-dark") ?? renderAllClear()
        default:  // "moon", and any unknown style
            return bundledImage(MoonPhase.imageName(onDayOf: Date())) ?? renderEmoji("🌙")
        }
    }

    private func renderAllClear() -> String {
        guard let ctx = makeKeyContext() else { return "" }
        Self.fillKeyBackground(ctx, size: size)
        let content = Self.drawCalendar(ctx, in: CGRect(x: 19, y: 24, width: 34, height: 34),
                                        page: nil, line: Palette.red,
                                        header: Palette.red, rings: Palette.red)
        Self.drawCheck(ctx, in: content, color: Palette.white)
        withNSGraphicsContext(ctx) {
            draw("All clear", font: .boldSystemFont(ofSize: 13), color: .white, alignment: .center,
                 in: CGRect(x: 2, y: 3, width: 68, height: 18))
        }
        return toPNGDataURI(ctx)
    }

    // Drawn with the system emoji font at run time, so no emoji artwork ships with the plugin.
    private func renderEmoji(_ emoji: String) -> String {
        guard let ctx = makeKeyContext() else { return "" }
        Self.fillKeyBackground(ctx, size: size)
        withNSGraphicsContext(ctx) {
            draw(emoji, font: .systemFont(ofSize: 42), color: .white, alignment: .center,
                 in: CGRect(x: 0, y: 6, width: 72, height: 58))
        }
        return toPNGDataURI(ctx)
    }

    // Text centered on the key, as large as fits.
    private func renderMessage(_ text: String) -> String {
        guard let ctx = makeKeyContext() else { return "" }
        Self.fillKeyBackground(ctx, size: size)
        withNSGraphicsContext(ctx) {
            drawFitted(text, color: NSColor(white: 0.88, alpha: 1),
                       in: CGRect(x: 4, y: 4, width: 64, height: 64))
        }
        return toPNGDataURI(ctx)
    }

    // Loads Images/<name>@2x.png (or <name>.png) as a data: URL, caching the result.
    private func bundledImage(_ name: String) -> String? {
        if let cached = cachedImages[name] { return cached }
        for file in ["\(name)@2x.png", "\(name).png"] {
            if let data = try? Data(contentsOf: imagesDirectory.appendingPathComponent(file)) {
                let uri = "data:image/png;base64," + data.base64EncodedString()
                cachedImages[name] = uri
                return uri
            }
        }
        return nil
    }

    // Shown when the helper reports that calendar access was refused.
    func renderNoAccess() -> String {
        guard let ctx = makeKeyContext() else { return "" }
        Self.fillKeyBackground(ctx, size: size)
        withNSGraphicsContext(ctx) {
            draw("⚠️", font: .systemFont(ofSize: 17), color: .white, alignment: .center,
                 in: CGRect(x: 0, y: 47, width: 72, height: 22))
            // Wraps to three lines: "No / calendar / access".
            draw("No calendar access", font: .boldSystemFont(ofSize: 11), color: .white, alignment: .center,
                 in: CGRect(x: 4, y: 2, width: 64, height: 44))
        }
        return toPNGDataURI(ctx)
    }

    // MARK: - Artwork (also used by Tools/ImageTool)

    enum Palette {
        static let keyBackground = CGColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1)
        static let red    = CGColor(red: 0.90, green: 0.15, blue: 0.15, alpha: 1)
        static let green  = CGColor(red: 0.20, green: 0.75, blue: 0.35, alpha: 1)
        static let white  = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    }

    private static func fillKeyBackground(_ ctx: CGContext, size: CGFloat) {
        ctx.setFillColor(Palette.keyBackground)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    }

    // Draws a calendar page filling the square `rect` and returns the area below
    // the header, for whatever goes on the page.
    @discardableResult
    static func drawCalendar(_ ctx: CGContext, in rect: CGRect, page: CGColor?, line: CGColor?,
                                     header: CGColor, rings: CGColor) -> CGRect {
        let s = rect.width
        let lineWidth = s * 0.08
        let body = CGRect(x: rect.minX + s * 0.06, y: rect.minY + s * 0.04, width: s * 0.88, height: s * 0.82)
        let radius = s * 0.14
        let bodyPath = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let headerHeight = body.height * 0.30

        if let page {
            ctx.setFillColor(page)
            ctx.addPath(bodyPath)
            ctx.fillPath()
        }

        ctx.saveGState()
        ctx.addPath(bodyPath)
        ctx.clip()
        ctx.setFillColor(header)
        ctx.fill(CGRect(x: body.minX, y: body.maxY - headerHeight, width: body.width, height: headerHeight))
        ctx.restoreGState()

        if let line {
            let inner = body.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            ctx.addPath(CGPath(roundedRect: inner, cornerWidth: radius - lineWidth / 2,
                               cornerHeight: radius - lineWidth / 2, transform: nil))
            ctx.setStrokeColor(line)
            ctx.setLineWidth(lineWidth)
            ctx.strokePath()
        }

        // Binder rings poking up through the header.
        let ringW = s * 0.10, ringH = s * 0.22
        ctx.setFillColor(rings)
        for x in [body.minX + body.width * 0.28, body.maxX - body.width * 0.28] {
            let ring = CGRect(x: x - ringW / 2, y: body.maxY - ringH * 0.6, width: ringW, height: ringH)
            ctx.addPath(CGPath(roundedRect: ring, cornerWidth: ringW / 2, cornerHeight: ringW / 2, transform: nil))
            ctx.fillPath()
        }

        // The page's open interior: below the header and, for an outlined page,
        // inside the outline.
        let inset = line == nil ? 0 : lineWidth
        return CGRect(x: body.minX + inset, y: body.minY + inset,
                      width: body.width - inset * 2, height: body.height - headerHeight - inset)
    }

    // Draws a checkmark centered in `r`. The check is laid out in its own box
    // (1.35:1, about 60% of r) and that box is centered, so the visible mark,
    // round ends included, has equal margins on opposite sides.
    static func drawCheck(_ ctx: CGContext, in r: CGRect, color: CGColor) {
        let aspect: CGFloat = 1.35
        var w = r.width * 0.60
        var h = w / aspect
        if h > r.height * 0.60 {
            h = r.height * 0.60
            w = h * aspect
        }
        let origin = CGPoint(x: r.midX - w / 2, y: r.midY - h / 2)

        ctx.setStrokeColor(color)
        ctx.setLineWidth(min(r.width, r.height) * 0.17)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: CGPoint(x: origin.x, y: origin.y + h * 0.50))
        ctx.addLine(to: CGPoint(x: origin.x + w * 0.36, y: origin.y))
        ctx.addLine(to: CGPoint(x: origin.x + w, y: origin.y + h))
        ctx.strokePath()
    }

    // MARK: - Drawing helpers

    private func makeKeyContext() -> CGContext? {
        guard let ctx = Self.makeContext(pixels: Int(size * scale)) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        return ctx
    }

    private static func makeContext(pixels: Int) -> CGContext? {
        CGContext(data: nil, width: pixels, height: pixels,
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

    // Draws bold, centered text as large as fits, centered vertically in rect.
    // Line breaks the user typed are kept. Sizing prefers whole words: the
    // largest size from 16 pt down to 10 pt where no word has to be split; if
    // a word is too long even at 10 pt, the largest size from 16 pt down to 7 pt
    // where the text fits with long words broken.
    private func drawFitted(_ text: String, color: NSColor, in rect: CGRect) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)

        func layout(_ fontSize: CGFloat) -> (text: NSAttributedString, height: CGFloat, wordsFit: Bool) {
            let font = NSFont.boldSystemFont(ofSize: fontSize)
            let attributed = NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: para
            ])
            let height = ceil(attributed.boundingRect(
                with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
            let widestWord = words.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
            return (attributed, height, widestWord <= rect.width)
        }

        let sizes = stride(from: CGFloat(16), through: 7, by: -1)
        let chosen = sizes.lazy.filter { $0 >= 10 }.map(layout).first { $0.height <= rect.height && $0.wordsFit }
            ?? sizes.lazy.map(layout).first { $0.height <= rect.height }
            ?? layout(7)

        // draw(in:) starts at the top of its rect and clips at the bottom, so give
        // it room below the measured height rather than an exact fit.
        let top = rect.minY + max(0, (rect.height - chosen.height) / 2) + chosen.height
        chosen.text.draw(in: CGRect(x: rect.minX, y: rect.minY - 8, width: rect.width, height: top - rect.minY + 8))
    }

    // Returns a strip color for 1–59 min, nil for ≥60 min (no strip) and 0 (handled separately).
    private func stripColorFor(minutes: Int) -> CGColor? {
        switch minutes {
        case 1..<6:   return Palette.red                                           // red
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

    // Strip a leading room/floor code, e.g. "101 " from "101 Team Standup" or
    // "4.2 - " from "4.2 - Review". The code must be followed by a space, so
    // titles like "1:1 with Sam" or "3D printing" are left alone.
    private static let roomCodePrefix = try? NSRegularExpression(pattern: #"^\d[\d.\-]*\s+(?:[-–—]\s+)?"#)

    private func keyTitle(_ title: String, reminder: Bool) -> String {
        reminder ? "○ " + cleanTitle(title) : cleanTitle(title)
    }

    private func cleanTitle(_ title: String) -> String {
        guard let regex = Self.roomCodePrefix,
              let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              let range = Range(match.range, in: title) else { return title }
        let cleaned = String(title[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? title : cleaned
    }

    private static func pngData(_ ctx: CGContext) throws -> Data {
        struct EncodeError: Error {}
        guard let image = ctx.makeImage() else { throw EncodeError() }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil)
        else { throw EncodeError() }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw EncodeError() }
        return data as Data
    }

    private func toPNGDataURI(_ ctx: CGContext) -> String {
        guard let data = try? Self.pngData(ctx) else { return "" }
        return "data:image/png;base64," + data.base64EncodedString()
    }
}
