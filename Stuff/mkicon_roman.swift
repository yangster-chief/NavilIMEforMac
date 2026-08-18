import Cocoa

// 1) 큰 캔버스에 A를 그리고 잉크 영역만 잘라낸다.
let big = NSSize(width: 200, height: 200)
let src = NSImage(size: big)
src.lockFocus()
NSColor.clear.set(); NSRect(origin: .zero, size: big).fill()
let s = NSAttributedString(string: "A", attributes: [
    .font: NSFont.systemFont(ofSize: 140, weight: .semibold),
    .foregroundColor: NSColor.black])
let sz = s.size()
s.draw(at: NSPoint(x: (big.width-sz.width)/2, y: (big.height-sz.height)/2))
src.unlockFocus()
guard let st = src.tiffRepresentation, let sr = NSBitmapImageRep(data: st) else { fatalError() }

var x0 = 9999, y0 = 9999, x1 = -1, y1 = -1
for y in 0..<sr.pixelsHigh { for x in 0..<sr.pixelsWide {
    guard let c = sr.colorAt(x: x, y: y), c.alphaComponent > 0.1 else { continue }
    x0 = min(x0,x); y0 = min(y0,y); x1 = max(x1,x); y1 = max(y1,y) }}
let iw = x1-x0+1, ih = y1-y0+1

// 2) navilime.png 와 같은 잉크 높이(32)로 맞춰 36x36 중앙에 배치.
let TARGET_H: CGFloat = 32, CANVAS: CGFloat = 36
let scale = TARGET_H / CGFloat(ih)
let dw = CGFloat(iw) * scale
let out = NSImage(size: NSSize(width: CANVAS, height: CANVAS))
out.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high
NSColor.clear.set(); NSRect(x: 0, y: 0, width: CANVAS, height: CANVAS).fill()
src.draw(in: NSRect(x: (CANVAS-dw)/2, y: (CANVAS-TARGET_H)/2, width: dw, height: TARGET_H),
         from: NSRect(x: CGFloat(x0), y: CGFloat(sr.pixelsHigh-y1-1), width: CGFloat(iw), height: CGFloat(ih)),
         operation: .sourceOver, fraction: 1.0)
out.unlockFocus()

guard let t = out.tiffRepresentation, let r = NSBitmapImageRep(data: t),
      let png = r.representation(using: .png, properties: [:]) else { fatalError() }
try! png.write(to: URL(fileURLWithPath: "/Users/yang/Documents/workspace/labs/NavilIMEforMac/NavilIME/navilime_roman.png"))
print("재생성 완료")
