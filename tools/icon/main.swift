// 生成 MacMon 应用图标：swiftc tools/icon/main.swift -o /tmp/mkicon && /tmp/mkicon out.png
// 风格：macOS Big Sur 规范的圆角方形（1024 画布内 824 主体），深色渐变底 + 彩色仪表弧 + 指针 + 脉搏线
import AppKit

let S: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let cs = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [r / 255, g / 255, b / 255, a])!
}

// —— 主体：圆角方形 + 投影 ——
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let radius: CGFloat = 185
let squircle = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.35))
ctx.addPath(squircle); ctx.setFillColor(rgb(20, 24, 36)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle); ctx.clip()
// 底色渐变：上浅下深的石墨蓝
let bg = CGGradient(colorsSpace: cs, colors: [rgb(44, 52, 74), rgb(16, 19, 30)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// 顶部柔光
let glow = CGGradient(colorsSpace: cs, colors: [rgb(120, 160, 255, 0.22), rgb(120, 160, 255, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 860), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 860), endRadius: 560, options: [])

// —— 仪表弧：绿 → 黄 → 橙 → 红，220° ——
let c = CGPoint(x: 512, y: 470)
let R: CGFloat = 270
let start: CGFloat = 200, end: CGFloat = -20      // 角度（度），从左下扫到右下
let stops: [(CGFloat, (CGFloat, CGFloat, CGFloat))] = [
    (0, (52, 199, 89)), (0.45, (255, 214, 10)), (0.72, (255, 149, 0)), (1, (255, 59, 48)),
]
func colorAt(_ t: CGFloat) -> CGColor {
    for i in 1..<stops.count where t <= stops[i].0 {
        let (t0, a) = stops[i - 1], (t1, b) = stops[i]
        let k = (t - t0) / (t1 - t0)
        return rgb(a.0 + (b.0 - a.0) * k, a.1 + (b.1 - a.1) * k, a.2 + (b.2 - a.2) * k)
    }
    let l = stops.last!.1
    return rgb(l.0, l.1, l.2)
}
// 底轨
ctx.setLineCap(.round)
ctx.setLineWidth(64)
ctx.setStrokeColor(rgb(255, 255, 255, 0.08))
ctx.addArc(center: c, radius: R, startAngle: start * .pi / 180, endAngle: end * .pi / 180, clockwise: true)
ctx.strokePath()
// 彩色弧（分段绘制实现角向渐变）
let steps = 220
ctx.setLineCap(.butt)
for i in 0..<steps {
    let t0 = CGFloat(i) / CGFloat(steps), t1 = CGFloat(i + 1) / CGFloat(steps)
    let a0 = (start + (end - start) * t0) * .pi / 180
    let a1 = (start + (end - start) * t1 + (i < steps - 1 ? -0.4 : 0)) * .pi / 180
    ctx.setStrokeColor(colorAt(t0))
    ctx.addArc(center: c, radius: R, startAngle: a0, endAngle: a1, clockwise: true)
    ctx.strokePath()
}
// 两端圆头
for (t, a) in [(CGFloat(0), start), (CGFloat(1), end)] {
    let r = a * .pi / 180
    ctx.setFillColor(colorAt(t))
    ctx.fillEllipse(in: CGRect(x: c.x + R * cos(r) - 32, y: c.y + R * sin(r) - 32, width: 64, height: 64))
}

// —— 刻度 ——
ctx.setLineCap(.round)
for i in 0...10 {
    let a = (start + (end - start) * CGFloat(i) / 10) * .pi / 180
    let r1: CGFloat = R - 62, r2: CGFloat = R - (i % 5 == 0 ? 104 : 86)
    ctx.setLineWidth(i % 5 == 0 ? 12 : 8)
    ctx.setStrokeColor(rgb(255, 255, 255, i % 5 == 0 ? 0.55 : 0.28))
    ctx.move(to: CGPoint(x: c.x + r1 * cos(a), y: c.y + r1 * sin(a)))
    ctx.addLine(to: CGPoint(x: c.x + r2 * cos(a), y: c.y + r2 * sin(a)))
    ctx.strokePath()
}

// —— 指针（指向约 2/3 处）——
let na = (start + (end - start) * 0.66) * .pi / 180
let tip = CGPoint(x: c.x + (R - 70) * cos(na), y: c.y + (R - 70) * sin(na))
let perp = na + .pi / 2
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: rgb(0, 0, 0, 0.5))
ctx.beginPath()
ctx.move(to: tip)
ctx.addLine(to: CGPoint(x: c.x + 22 * cos(perp), y: c.y + 22 * sin(perp)))
ctx.addLine(to: CGPoint(x: c.x - 40 * cos(na), y: c.y - 40 * sin(na)))
ctx.addLine(to: CGPoint(x: c.x - 22 * cos(perp), y: c.y - 22 * sin(perp)))
ctx.closePath()
ctx.setFillColor(rgb(255, 255, 255))
ctx.fillPath()
ctx.fillEllipse(in: CGRect(x: c.x - 44, y: c.y - 44, width: 88, height: 88))
ctx.restoreGState()
ctx.setFillColor(rgb(30, 36, 52))
ctx.fillEllipse(in: CGRect(x: c.x - 18, y: c.y - 18, width: 36, height: 36))

// —— 底部脉搏线 ——
let y0: CGFloat = 238
let pulse: [CGPoint] = [
    CGPoint(x: 250, y: y0), CGPoint(x: 410, y: y0), CGPoint(x: 450, y: y0 + 46), CGPoint(x: 500, y: y0 - 78),
    CGPoint(x: 548, y: y0 + 96), CGPoint(x: 590, y: y0), CGPoint(x: 774, y: y0),
]
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 22, color: rgb(90, 200, 250, 0.8))
ctx.setLineWidth(20); ctx.setLineJoin(.round); ctx.setLineCap(.round)
ctx.setStrokeColor(rgb(100, 210, 255))
ctx.addLines(between: pulse)
ctx.strokePath()
ctx.restoreGState()

// 内描边高光
ctx.addPath(squircle)
ctx.setLineWidth(4)
ctx.setStrokeColor(rgb(255, 255, 255, 0.10))
ctx.strokePath()
ctx.restoreGState()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("✅ \(out)")
