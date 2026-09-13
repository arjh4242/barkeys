import Cocoa

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let rect = NSRect(x: 0, y: 0, width: size, height: size)
let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22)
path.addClip()

let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.36, green: 0.32, blue: 0.92, alpha: 1.0),
    NSColor(calibratedRed: 0.62, green: 0.28, blue: 0.80, alpha: 1.0)
])
gradient?.draw(in: rect, angle: -90)

let text = "⌘"
let font = NSFont.systemFont(ofSize: size * 0.58, weight: .bold)
let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor.white,
    .paragraphStyle: paragraph
]
let attrString = NSAttributedString(string: text, attributes: attrs)
let textSize = attrString.size()
let textRect = NSRect(
    x: (size - textSize.width) / 2,
    y: (size - textSize.height) / 2 - size * 0.02,
    width: textSize.width,
    height: textSize.height
)
attrString.draw(in: textRect)

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Kunne ikke generere ikon")
}

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try png.write(to: URL(fileURLWithPath: outputPath))
print("Skrev \(outputPath)")
