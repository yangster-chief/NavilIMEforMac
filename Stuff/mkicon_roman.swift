import Cocoa

// navilime.png 와 같은 틀로 영문 모드 아이콘을 만든다.
// 그 파일은 36x36 캔버스에 2px 테두리 상자(행 2..33)를 두르고 그 안에 글자를
// 22px 높이(행 6..27)로 넣은 구조다. 테두리가 없으면 메뉴에서 ABC/한글 항목과
// 나란히 놓였을 때 혼자 떠 보인다.
//
// NSImage.lockFocus() 는 Retina 화면에서 2x 백킹을 잡아 72x72 가 나온다.
// 픽셀을 정확히 맞춰야 하므로 NSBitmapImageRep 을 직접 만들어 그린다.

func makeRep(_ w: Int, _ h: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                     isPlanar: false, colorSpaceName: .deviceRGB,
                     bytesPerRow: 0, bitsPerPixel: 0)!
}
func draw(into rep: NSBitmapImageRep, _ body: () -> Void) {
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    body()
    ctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
}
func attrs(_ size: CGFloat) -> [NSAttributedString.Key: Any] {
    [.font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: NSColor.black]
}

// 1) 큰 캔버스에 A 를 그려 잉크 영역을 실측한다. (글꼴 여백은 글자마다 다르다)
let PROBE: CGFloat = 140, N = 300
let origin = NSPoint(x: 50, y: 50)
let probe = makeRep(N, N)
draw(into: probe) {
    NSAttributedString(string: "A", attributes: attrs(PROBE)).draw(at: origin)
}
var minC = N, maxC = -1, minR = N, maxR = -1
for r in 0..<N { for c in 0..<N {
    guard let p = probe.colorAt(x: c, y: r), p.alphaComponent > 0.1 else { continue }
    minC = min(minC,c); maxC = max(maxC,c); minR = min(minR,r); maxR = max(maxR,r) }}
let inkW = CGFloat(maxC-minC+1), inkH = CGFloat(maxR-minR+1)
// colorAt 은 위→아래, 그리기는 아래→위 좌표라 뒤집어서 원점 기준 오프셋을 구한다.
let offX = CGFloat(minC) - origin.x
let offY = CGFloat(N-1-maxR) - origin.y

// 2) 36x36 에 테두리 상자를 그리고 그 안에 A 를 22px 높이로 넣는다.
//    행 r(위→아래) 는 아래→위 좌표 [35-r, 36-r) 에 대응한다.
let C = 36, B: CGFloat = 2, TOP: CGFloat = 32, BOT: CGFloat = 2, INK_H: CGFloat = 22
let out = makeRep(C, C)
draw(into: out) {
    NSColor.black.set()
    NSRect(x: 0, y: TOP, width: CGFloat(C), height: B).fill()              // 위
    NSRect(x: 0, y: BOT, width: CGFloat(C), height: B).fill()              // 아래
    NSRect(x: 0, y: BOT, width: B, height: TOP-BOT+B).fill()               // 왼쪽
    NSRect(x: CGFloat(C)-B, y: BOT, width: B, height: TOP-BOT+B).fill()    // 오른쪽

    let k = INK_H / inkH                       // 잉크 높이를 22 로 맞추는 배율
    let at = NSPoint(x: (CGFloat(C) - inkW*k)/2 - offX*k,   // 가로 중앙
                     y: 8 - offY*k)                        // 행 6..27 = y 8..29
    NSAttributedString(string: "A", attributes: attrs(PROBE*k)).draw(at: at)
}

// navilime.png 는 36x36px 를 18x18pt 로 태그한 Retina 2x 이미지다(144dpi).
// 이 값을 맞추지 않으면 픽셀 수가 같아도 화면에서 정확히 2배로 그려진다.
out.size = NSSize(width: CGFloat(C)/2, height: CGFloat(C)/2)
guard let png = out.representation(using: .png, properties: [:]) else { fatalError() }
let dst = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("NavilIME/navilime_roman.png")
try! png.write(to: dst)
print("재생성 완료: \(dst.path)")
