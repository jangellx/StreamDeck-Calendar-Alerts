import AppKit

// Writes the action-list and category icons (white glyphs on transparent) into
// Images/, and sample key images for the README into docs/images/.
// Built and run by Tools/make-images.sh together with ButtonImageRenderer.swift.

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let imagesDir = root.appendingPathComponent("Images")
let docsDir = root.appendingPathComponent("docs/images")
let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

func writePNG(pixels: Int, to url: URL, draw: (CGContext) -> Void) throws {
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                          CGBitmapInfo.byteOrder32Little.rawValue),
          let image = (draw(ctx), ctx.makeImage()).1,
          let rep = Optional(NSBitmapImageRep(cgImage: image)),
          let data = rep.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url)
}

func drawBell(_ ctx: CGContext, center c: CGPoint, size b: CGFloat) {
    ctx.setFillColor(white)
    let baseY = c.y - 0.22 * b
    let dome = CGMutablePath()
    dome.move(to: CGPoint(x: c.x - 0.40 * b, y: baseY))
    dome.addCurve(to: CGPoint(x: c.x, y: c.y + 0.40 * b),
                  control1: CGPoint(x: c.x - 0.36 * b, y: c.y + 0.10 * b),
                  control2: CGPoint(x: c.x - 0.30 * b, y: c.y + 0.40 * b))
    dome.addCurve(to: CGPoint(x: c.x + 0.40 * b, y: baseY),
                  control1: CGPoint(x: c.x + 0.30 * b, y: c.y + 0.40 * b),
                  control2: CGPoint(x: c.x + 0.36 * b, y: c.y + 0.10 * b))
    dome.closeSubpath()
    ctx.addPath(dome)
    ctx.fillPath()
    let lip = CGRect(x: c.x - 0.50 * b, y: baseY - 0.10 * b, width: b, height: 0.12 * b)
    ctx.addPath(CGPath(roundedRect: lip, cornerWidth: 0.06 * b, cornerHeight: 0.06 * b, transform: nil))
    ctx.fillPath()
    ctx.fillEllipse(in: CGRect(x: c.x - 0.10 * b, y: baseY - 0.30 * b, width: 0.20 * b, height: 0.20 * b))
}

// Calendar outline with a bell: the action and category icon.
func drawGlyph(_ ctx: CGContext, points s: CGFloat) {
    let page = ButtonImageRenderer.drawCalendar(ctx, in: CGRect(x: 0, y: 0, width: s, height: s),
                                                page: nil, line: white, header: white, rings: white)
    drawBell(ctx, center: CGPoint(x: page.midX, y: page.midY + page.height * 0.04), size: page.height * 0.62)
}

// Elgato's sizes: action list 20 px, category 28 px, each with an @2x version.
for (name, points) in [("action", CGFloat(20)), ("category", CGFloat(28))] {
    for (suffix, factor) in [("", CGFloat(1)), ("@2x", CGFloat(2))] {
        try writePNG(pixels: Int(points * factor),
                     to: imagesDir.appendingPathComponent("\(name)\(suffix).png")) { ctx in
            ctx.scaleBy(x: factor, y: factor)
            drawGlyph(ctx, points: points)
        }
    }
}

// README samples, rendered exactly as the plugin draws them.
let renderer = ButtonImageRenderer(scale: 2, imagesDirectory: imagesDir)
let samples: [(String, String)] = [
    ("key-90m", renderer.renderEvent(title: "Quarterly planning", minutesUntil: 90)),
    ("key-45m", renderer.renderEvent(title: "Design review", minutesUntil: 45)),
    ("key-25m", renderer.renderEvent(title: "Team standup", minutesUntil: 25)),
    ("key-12m", renderer.renderEvent(title: "1:1 with Sam", minutesUntil: 12)),
    ("key-8m", renderer.renderEvent(title: "Customer call", minutesUntil: 8)),
    ("key-3m", renderer.renderEvent(title: "Dentist", minutesUntil: 3)),
    ("key-now", renderer.renderEvent(title: "Dentist", minutesUntil: 0, flashPhase: true)),
    ("key-now-off", renderer.renderEvent(title: "Dentist", minutesUntil: 0, flashPhase: false)),   // NOW's other flash frame, for the website
    ("key-all-day", renderer.renderAllDay(title: "Mom's birthday")),
    ("no-events-loop", renderer.renderNoEvents(style: "loop")),
    ("no-events-loop-dark", renderer.renderNoEvents(style: "loop-dark")),
    ("no-events-smile", renderer.renderNoEvents(style: "smile")),
    ("no-events-smile-dark", renderer.renderNoEvents(style: "smile-dark")),
    ("no-events-check", renderer.renderNoEvents(style: "check")),
    ("no-events-moon", renderer.renderNoEvents(style: "moon")),
    ("no-events-text", renderer.renderNoEvents(style: "text")),
]
try FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)
for (name, uri) in samples {
    let base64 = uri.replacingOccurrences(of: "data:image/png;base64,", with: "")
    guard let data = Data(base64Encoded: base64) else { continue }
    try data.write(to: docsDir.appendingPathComponent("\(name).png"))
}
print("Wrote icons to \(imagesDir.path) and samples to \(docsDir.path)")
