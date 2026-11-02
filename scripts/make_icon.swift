// Draws Pixora's icon: a contact-sheet frame on darkroom charcoal with a safelight-amber face mark.
import AppKit
let size = 1024
let out = CommandLine.arguments[1]
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let s = CGFloat(size)
let body = CGRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
ctx.addPath(CGPath(roundedRect: body, cornerWidth: s * 0.18, cornerHeight: s * 0.18, transform: nil))
ctx.setFillColor(CGColor(srgbRed: 0.09, green: 0.085, blue: 0.08, alpha: 1)); ctx.fillPath()
// film sprocket holes
ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.93, blue: 0.89, alpha: 0.18))
for i in 0..<6 {
    let x = body.minX + s * 0.1 + CGFloat(i) * s * 0.115
    for y in [body.minY + s * 0.06, body.maxY - s * 0.1] {
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: s * 0.06, height: s * 0.04), cornerWidth: 8, cornerHeight: 8, transform: nil)); ctx.fillPath()
    }
}
// frame
let frame = CGRect(x: body.minX + s * 0.1, y: body.minY + s * 0.17, width: body.width - s * 0.2, height: body.height - s * 0.34)
ctx.setStrokeColor(CGColor(srgbRed: 0.95, green: 0.93, blue: 0.89, alpha: 0.9)); ctx.setLineWidth(s * 0.012); ctx.stroke(frame)
// two faces (head + shoulders), one amber = selected
func person(_ cx: CGFloat, _ color: CGColor) {
    ctx.setFillColor(color)
    ctx.fillEllipse(in: CGRect(x: cx - s * 0.075, y: frame.minY + s * 0.2, width: s * 0.15, height: s * 0.15))
    ctx.addPath(CGPath(roundedRect: CGRect(x: cx - s * 0.13, y: frame.minY + s * 0.02, width: s * 0.26, height: s * 0.16), cornerWidth: s * 0.08, cornerHeight: s * 0.08, transform: nil))
    ctx.fillPath()
}
person(frame.midX - s * 0.13, CGColor(srgbRed: 0.94, green: 0.53, blue: 0.29, alpha: 1))
person(frame.midX + s * 0.13, CGColor(srgbRed: 0.95, green: 0.93, blue: 0.89, alpha: 0.85))
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
