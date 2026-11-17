// Nexus.app 아이콘 렌더러. `swift render-icon.swift out.png [size]`
// 시안 06 "Terminal": 검정 스쿼클 + 초록 `>_` 프롬프트 + 오른쪽 위 작은 3노드 연결점.
// 규격(Apple macOS 아이콘 템플릿): 1024 캔버스 / 824 스쿼클 / 여백 100 / 코너 185.4 continuous / 그림자 검정 50% blur 28 y-12.
import AppKit
import SwiftUI

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "AppIcon-1024.png"
let S = CGFloat(args.count > 2 ? Double(args[2]) ?? 1024 : 1024)

// 1x 비트맵에 직접 그린다 (lockFocus 는 화면 배율을 따라 2x 가 된다)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: S, height: S)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor { NSColor(calibratedRed: r, green: g, blue: b, alpha: a) }
let green = rgb(0.29, 0.87, 0.50)
let bgTop = rgb(0.10, 0.10, 0.12)
let bgBottom = rgb(0.02, 0.02, 0.03)

// 스쿼클: Apple continuous 코너 (SwiftUI 의 .continuous 가 시스템과 같은 곡선)
let inset = S * 100 / 1024
let rect = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
let radius = rect.width * 185.4 / 824
func squircle(_ r: CGRect) -> CGPath { RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: r).cgPath }

// 규격 드롭 섀도
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -S * 12 / 1024), blur: S * 28 / 1024, color: NSColor(white: 0, alpha: 0.5).cgColor)
ctx.addPath(squircle(rect)); ctx.setFillColor(bgBottom.cgColor); ctx.fillPath()
ctx.restoreGState()

// 배경 그라데이션
ctx.saveGState()
ctx.addPath(squircle(rect)); ctx.clip()
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [bgTop.cgColor, bgBottom.cgColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
ctx.restoreGState()

// 안쪽 테두리 (미세한 하이라이트)
ctx.saveGState()
ctx.addPath(squircle(rect)); ctx.clip()
ctx.addPath(squircle(rect.insetBy(dx: S * 0.004, dy: S * 0.004)))
ctx.setStrokeColor(NSColor(white: 1, alpha: 0.10).cgColor); ctx.setLineWidth(S * 0.008); ctx.strokePath()
ctx.restoreGState()

// `>_` 프롬프트
let center = CGPoint(x: rect.midX, y: rect.midY)
let font = NSFont.monospacedSystemFont(ofSize: S * 0.44, weight: .bold)
let prompt = NSAttributedString(string: ">_", attributes: [.font: font, .foregroundColor: green])
let size = prompt.size()
prompt.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y + S * 0.04 - size.height / 2))

// 오른쪽 위 3노드 연결점
func pt(_ c: CGPoint, _ r: CGFloat, _ deg: CGFloat) -> CGPoint { CGPoint(x: c.x + r * cos(deg * .pi / 180), y: c.y + r * sin(deg * .pi / 180)) }
let hub = CGPoint(x: rect.maxX - S * 0.16, y: rect.maxY - S * 0.16)
let leaves = [pt(hub, S * 0.09, 210), pt(hub, S * 0.09, 300)]
for leaf in leaves {
    let p = NSBezierPath(); p.move(to: hub); p.line(to: leaf)
    p.lineWidth = S * 0.012; p.lineCapStyle = .round; green.withAlphaComponent(0.6).setStroke(); p.stroke()
}
for node in [hub] + leaves {
    let r = S * 0.022
    green.setFill(); NSBezierPath(ovalIn: CGRect(x: node.x - r, y: node.y - r, width: r * 2, height: r * 2)).fill()
}

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) \(Int(S))x\(Int(S))")
