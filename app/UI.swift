// MacMon — SwiftUI 界面（菜单栏弹窗 + 监控窗口 + 设置）
//
// 开销控制：界面只在弹窗/窗口可见时才接收数据刷新；关闭后 SwiftUI 完全不参与计算。
import SwiftUI
import AppKit

// MARK: - 数据模型

struct History {
    static let cap = 60   // 60 × 3 秒 = 3 分钟
    var cpu: [Double] = []
    var mem: [Double] = []
    var netIn: [Double] = []
    var netOut: [Double] = []
    var ioR: [Double] = []
    var ioW: [Double] = []

    private static func push(_ a: inout [Double], _ v: Double) {
        a.append(v)
        if a.count > cap { a.removeFirst(a.count - cap) }
    }

    mutating func add(cpu c: Double, mem m: Double, net: NetSnap, io: DiskIOSnap) {
        Self.push(&cpu, c)
        Self.push(&mem, m)
        Self.push(&netIn, net.inRate)
        Self.push(&netOut, net.outRate)
        Self.push(&ioR, io.readRate)
        Self.push(&ioW, io.writeRate)
    }
}

struct SelfStats {
    var cpuPct: Double = 0
    var footprint: UInt64 = 0
    var tickMs: Double = 0
}

struct Snapshot {
    var cpu: CPUSnap?
    var mem: MemSnap?
    var load: (Double, Double, Double)?
    var cores: Int = ProcessInfo.processInfo.activeProcessorCount
    var net = NetSnap()
    var io = DiskIOSnap()
    var volumes: [Volume] = []
    var topCpu: [ProcCPU] = []
    var apps: [AppUsage] = []
    var history = History()
    var thermal: ProcessInfo.ThermalState = .nominal
    var me = SelfStats()

    var busy: Double { cpu.map { 100 - $0.idle } ?? 0 }
    var memFrac: Double { mem.map { Double($0.used) / Double(max($0.total, 1)) } ?? 0 }
}

enum Health { case good, warn, bad }

extension Snapshot {
    /// 整体健康度 + 一句话说明
    var health: (Health, String) {
        if let m = mem, m.pressure == .critical { return (.bad, "内存严重不足，系统正在卡顿") }
        if busy >= 90 { return (.bad, "CPU 满载") }
        if thermal == .critical || thermal == .serious { return (.bad, "机器过热，正在降频") }
        if let m = mem, m.pressure == .warning { return (.warn, "内存压力较大") }
        if busy >= 70 { return (.warn, "CPU 繁忙") }
        if let m = mem, m.swapTotal > 0, Double(m.swapUsed) / Double(m.swapTotal) > 0.8 { return (.warn, "Swap 偏高") }
        if volumes.contains(where: { $0.root && $0.free < 10 << 30 }) { return (.warn, "磁盘空间不足") }
        return (.good, "一切正常")
    }
}

/// 反查 IP 对应的域名。getnameinfo 可能卡几十秒，所以：后台并发队列、最多 4 个同时进行、
/// 名额满了直接跳过（下次刷新再试）、结果缓存。界面永远只读缓存，绝不等待。
final class HostResolver: ObservableObject {
    @Published private(set) var version = 0
    private var cache: [String: String] = [:]   // ip → 域名（"" = 查不到）
    private var inflight = Set<String>()
    private let q = DispatchQueue(label: "com.ck.macmon.dns", qos: .utility, attributes: .concurrent)
    private let slots = DispatchSemaphore(value: 4)

    static func isProxyFakeIP(_ ip: String) -> Bool { ip.hasPrefix("198.18.") || ip.hasPrefix("198.19.") }

    static func isPrivate(_ ip: String) -> Bool {
        if ip.hasPrefix("10.") || ip.hasPrefix("192.168.") || ip.hasPrefix("127.") || ip.hasPrefix("169.254.")
            || ip == "::1" || ip.lowercased().hasPrefix("fe80") || ip.lowercased().hasPrefix("fd") { return true }
        if ip.hasPrefix("172."), let second = Int(ip.split(separator: ".").dropFirst().first ?? ""), (16...31).contains(second) { return true }
        return false
    }

    func host(_ ip: String) -> String? {
        _ = version
        if let h = cache[ip] { return h.isEmpty ? nil : h }
        if ip.isEmpty || Self.isProxyFakeIP(ip) || Self.isPrivate(ip) { cache[ip] = ""; return nil }
        guard !inflight.contains(ip), slots.wait(timeout: .now()) == .success else { return nil }
        inflight.insert(ip)
        q.async { [weak self] in
            let h = Self.reverse(ip)
            self?.slots.signal()
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.cache.count > 4000 { self.cache.removeAll() }
                self.cache[ip] = h ?? ""
                self.inflight.remove(ip)
                self.version &+= 1
            }
        }
        return nil
    }

    private static func reverse(_ ip: String) -> String? {
        var hints = addrinfo(ai_flags: AI_NUMERICHOST, ai_family: AF_UNSPEC, ai_socktype: 0, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(ip, nil, &hints, &res) == 0, let ai = res else { return nil }
        defer { freeaddrinfo(res) }
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NAMEREQD) == 0 else { return nil }
        return String(cString: buf)
    }
}

final class Model: ObservableObject {
    @Published var snap = Snapshot()
    @Published var paused = false
    @Published var agentOn = false
    @Published private var iconTick = 0

    /// 由 AppDelegate 注入的动作
    var kill: (String, [pid_t]) -> Void = { _, _ in }
    var openWindow: () -> Void = {}
    var openSettings: () -> Void = {}
    var togglePause: () -> Void = {}
    var toggleAgent: () -> Void = {}
    var testNotify: () -> Void = {}
    var revealLog: () -> Void = {}
    var quit: () -> Void = {}

    let dns = HostResolver()
    /// 连接明细在独立后台队列读取，不占用采样队列和主线程
    let connQ = DispatchQueue(label: "com.ck.macmon.conns", qos: .userInitiated)
    func loadConns(_ pids: [pid_t]) async -> [Conn] {
        await withCheckedContinuation { c in connQ.async { c.resume(returning: connDetails(pids)) } }
    }

    // —— 应用图标：后台加载 + 缓存，绝不在主线程读磁盘 ——
    private var icons: [String: NSImage] = [:]
    private var loading = Set<String>()
    private let iconQ = DispatchQueue(label: "com.ck.macmon.icons", qos: .utility)

    func icon(_ path: String?) -> NSImage? {
        _ = iconTick
        guard let p = path else { return nil }
        if let i = icons[p] { return i }
        if !loading.contains(p) {
            loading.insert(p)
            iconQ.async { [weak self] in
                let img = NSWorkspace.shared.icon(forFile: p)
                img.size = NSSize(width: 32, height: 32)
                DispatchQueue.main.async {
                    self?.icons[p] = img
                    self?.iconTick &+= 1
                }
            }
        }
        return nil
    }
}

// MARK: - 配色

extension Health {
    var color: Color {
        switch self {
        case .good: return .green
        case .warn: return .orange
        case .bad: return .red
        }
    }
}

func levelColor(_ v: Double, warn: Double, bad: Double, base: Color) -> Color {
    v >= bad ? .red : (v >= warn ? .orange : base)
}

extension Pressure {
    var label: String {
        switch self {
        case .normal: return "正常"
        case .warning: return "警告"
        case .critical: return "严重"
        }
    }
    var color: Color {
        switch self {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

// MARK: - 基础组件

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

struct CardHeader: View {
    let symbol: String
    let title: String
    let tint: Color
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}

struct Ring: View {
    let value: Double
    let tint: Color
    var line: CGFloat = 5
    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.16), lineWidth: line)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, value)))
                .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// 折线 + 渐变填充，可叠加多条（共享纵轴）
struct Sparkline: View {
    let series: [([Double], Color)]
    var fixedMax: Double? = nil

    var body: some View {
        GeometryReader { g in
            let mx = fixedMax ?? max(series.flatMap { $0.0 }.max() ?? 0, 1e-9)
            ZStack {
                ForEach(series.indices, id: \.self) { i in
                    let (data, tint) = series[i]
                    area(data, mx, g.size).fill(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.02)],
                                                               startPoint: .top, endPoint: .bottom))
                    line(data, mx, g.size).stroke(tint, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    private func pts(_ d: [Double], _ mx: Double, _ s: CGSize) -> [CGPoint] {
        let n = History.cap
        let start = n - d.count
        return d.enumerated().map { i, v in
            CGPoint(x: s.width * CGFloat(start + i) / CGFloat(n - 1),
                    y: s.height * (1 - CGFloat(min(v / mx, 1))) )
        }
    }

    private func line(_ d: [Double], _ mx: Double, _ s: CGSize) -> Path {
        Path { p in
            let ps = pts(d, mx, s)
            guard let f = ps.first else { return }
            p.move(to: f)
            ps.dropFirst().forEach { p.addLine(to: $0) }
        }
    }

    private func area(_ d: [Double], _ mx: Double, _ s: CGSize) -> Path {
        Path { p in
            let ps = pts(d, mx, s)
            guard let f = ps.first, let l = ps.last else { return }
            p.move(to: CGPoint(x: f.x, y: s.height))
            ps.forEach { p.addLine(to: $0) }
            p.addLine(to: CGPoint(x: l.x, y: s.height))
            p.closeSubpath()
        }
    }
}

struct Bar: View {
    let value: Double
    let tint: Color
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(tint).frame(width: max(height, g.size.width * CGFloat(min(1, max(0, value)))))
            }
        }
        .frame(height: height)
    }
}

struct AppIcon: View {
    @ObservedObject var m: Model
    let path: String?
    var size: CGFloat = 20
    var body: some View {
        if let img = m.icon(path) {
            Image(nsImage: img).resizable().frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(Color.secondary.opacity(0.18))
                .frame(width: size, height: size)
                .overlay(Image(systemName: "gearshape.fill").font(.system(size: size * 0.5)).foregroundStyle(.secondary))
        }
    }
}

// MARK: - 指标卡片

struct CPUCard: View {
    let s: Snapshot
    var tall = false
    var body: some View {
        let tint = levelColor(s.busy, warn: 70, bad: 90, base: .blue)
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(symbol: "cpu", title: "CPU", tint: tint)
                HStack(spacing: 10) {
                    ZStack {
                        Ring(value: s.busy / 100, tint: tint)
                        Text("\(Int(s.busy.rounded()))").font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                    }
                    .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "用户 %.0f%%", s.cpu?.user ?? 0))
                        Text(String(format: "系统 %.0f%%", s.cpu?.sys ?? 0))
                        if let l = s.load { Text(String(format: "负载 %.1f", l.0)) }
                    }
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit()
                }
                if tall, let per = s.cpu?.perCore, !per.isEmpty {
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(per.indices, id: \.self) { i in
                            GeometryReader { g in
                                VStack(spacing: 0) {
                                    Spacer(minLength: 0)
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(levelColor(per[i], warn: 70, bad: 90, base: .blue).gradient)
                                        .frame(height: max(2, g.size.height * per[i] / 100))
                                }
                            }
                            .background(RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.06)))
                        }
                    }
                    .frame(height: 28)
                    .help("每个核心的占用")
                }
                Sparkline(series: [(s.history.cpu, tint)], fixedMax: 100).frame(height: tall ? 46 : 28)
            }
        }
    }
}

struct MemCard: View {
    let s: Snapshot
    var tall = false
    var body: some View {
        let p = s.mem?.pressure ?? .normal
        let tint: Color = p == .normal ? .green : p.color
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(symbol: "memorychip", title: "内存", tint: tint)
                HStack(spacing: 10) {
                    ZStack {
                        Ring(value: s.memFrac, tint: tint)
                        Text("\(Int((s.memFrac * 100).rounded()))").font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                    }
                    .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        if let m = s.mem {
                            Text("\(bytes(m.used)) / \(bytes(m.total))")
                            HStack(spacing: 3) {
                                Circle().fill(p.color).frame(width: 6, height: 6)
                                Text("压力\(p.label)")
                            }
                            if m.swapTotal > 0 { Text("Swap \(bytes(m.swapUsed))") }
                        }
                    }
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit()
                }
                if tall, let m = s.mem { MemBreakdown(m: m) }
                Sparkline(series: [(s.history.mem, tint)], fixedMax: 100).frame(height: tall ? 46 : 28)
            }
        }
    }
}

/// 类似「关于本机 → 储存空间」的分段条
struct MemBreakdown: View {
    let m: MemSnap
    var body: some View {
        let parts: [(String, UInt64, Color)] = [
            ("App", m.app, .green), ("联动", m.wired, .orange), ("压缩", m.compressed, .purple), ("缓存", m.cached, .gray.opacity(0.6)),
        ]
        let total = Double(max(m.total, 1))
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { g in
                HStack(spacing: 1.5) {
                    ForEach(parts.indices, id: \.self) { i in
                        Rectangle().fill(parts[i].2).frame(width: max(0, g.size.width * Double(parts[i].1) / total - 1.5))
                    }
                    Spacer(minLength: 0)
                }
                .clipShape(Capsule())
                .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            .frame(height: 7)
            HStack(spacing: 8) {
                ForEach(parts.indices, id: \.self) { i in
                    HStack(spacing: 3) {
                        Circle().fill(parts[i].2).frame(width: 6, height: 6)
                        Text("\(parts[i].0) \(bytes(parts[i].1))")
                    }
                }
            }
            .font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

struct DualRateCard: View {
    let symbol: String
    let title: String
    let aLabel: String, a: Double, aColor: Color, aHist: [Double]
    let bLabel: String, b: Double, bColor: Color, bHist: [Double]
    var tall = false
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(symbol: symbol, title: title, tint: aColor)
                VStack(alignment: .leading, spacing: 3) {
                    rateLine(aLabel, a, aColor)
                    rateLine(bLabel, b, bColor)
                }
                .frame(height: 40, alignment: .center)
                Sparkline(series: [(aHist, aColor), (bHist, bColor)]).frame(height: tall ? 46 : 28)
            }
        }
    }

    private func rateLine(_ l: String, _ v: Double, _ c: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: l).font(.system(size: 10, weight: .bold)).foregroundStyle(c).frame(width: 12)
            Text(rate(v)).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
        }
    }
}

func netCard(_ s: Snapshot, tall: Bool = false) -> DualRateCard {
    DualRateCard(symbol: "network", title: "网络",
                 aLabel: "arrow.down", a: s.net.inRate, aColor: .blue, aHist: s.history.netIn,
                 bLabel: "arrow.up", b: s.net.outRate, bColor: .orange, bHist: s.history.netOut, tall: tall)
}

func ioCard(_ s: Snapshot, tall: Bool = false) -> DualRateCard {
    DualRateCard(symbol: "internaldrive", title: "磁盘读写",
                 aLabel: "arrow.down.doc", a: s.io.readRate, aColor: .teal, aHist: s.history.ioR,
                 bLabel: "square.and.pencil", b: s.io.writeRate, bColor: .pink, bHist: s.history.ioW, tall: tall)
}

// MARK: - 存储

struct VolumesView: View {
    let vols: [Volume]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("存储")
            Card {
                VStack(spacing: 10) {
                    ForEach(vols) { v in VolumeRow(v: v) }
                    if vols.isEmpty { Text("没有可显示的磁盘").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }
}

struct VolumeRow: View {
    let v: Volume
    var body: some View {
        let tint = levelColor(v.usedFraction * 100, warn: 85, bad: 95, base: .accentColor)
        HStack(spacing: 10) {
            Image(systemName: v.root ? "internaldrive.fill" : (v.local ? "externaldrive.fill" : "server.rack"))
                .font(.system(size: 16)).foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(v.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if !v.local {
                        Text("网络").font(.system(size: 9, weight: .medium)).padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                    Spacer()
                    Text("可用 \(bytes(v.free))").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
                Bar(value: v.usedFraction, tint: tint, height: 5)
                Text("共 \(bytes(v.total)) · \(v.fsType.uppercased())").font(.system(size: 9.5)).foregroundStyle(.tertiary)
            }
        }
        .help(v.mount)
    }
}

// MARK: - 应用 / 进程排行

enum SortKey: String, CaseIterable, Identifiable {
    case cpu = "CPU", mem = "内存", disk = "磁盘", conn = "连接"
    var id: String { rawValue }
}

struct RowItem: Identifiable {
    let id: String
    let name: String
    let path: String?
    let count: Int
    let pid: pid_t
    let pct: Double
    let mem: UInt64
    let disk: Double
    let conns: Int
    let listens: Int
    let pids: [pid_t]
}

func items(_ s: Snapshot, byApp: Bool, sort: SortKey, limit: Int) -> [RowItem] {
    var rows: [RowItem]
    if byApp {
        rows = s.apps.map { RowItem(id: $0.name, name: $0.name, path: $0.appPath, count: $0.pids.count,
                                    pid: $0.mainPid, pct: $0.pct, mem: $0.mem, disk: $0.diskRate,
                                    conns: $0.conns, listens: $0.listens, pids: $0.pids) }
    } else {
        rows = s.topCpu.map { RowItem(id: "\($0.p.pid)", name: $0.p.name, path: $0.p.appPath, count: 1,
                                      pid: $0.p.pid, pct: $0.pct, mem: $0.p.mem, disk: $0.diskRate,
                                      conns: $0.conns, listens: $0.listens, pids: [$0.p.pid]) }
    }
    switch sort {
    case .cpu: rows.sort { $0.pct > $1.pct }
    case .mem: rows.sort { $0.mem > $1.mem }
    case .disk: rows.sort { $0.disk > $1.disk }
    case .conn: rows.sort { ($0.conns, $0.listens) > ($1.conns, $1.listens) }
    }
    return Array(rows.prefix(limit))
}

struct AppRow: View {
    @ObservedObject var m: Model
    let r: RowItem
    let sort: SortKey
    var wide = false
    @State private var hover = false
    @State private var showConns = false

    var body: some View {
        HStack(spacing: 8) {
            AppIcon(m: m, path: r.path, size: wide ? 20 : 18)
            Text(r.name).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
            if r.count > 1 {
                Text("×\(r.count)").font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }
            Spacer(minLength: 6)
            if wide {
                Group {
                    Text(r.count > 1 ? "\(r.count) 个" : String(r.pid)).frame(width: 60, alignment: .trailing).foregroundStyle(.secondary)
                    Text(String(format: "%.1f%%", r.pct)).frame(width: 64, alignment: .trailing)
                        .foregroundStyle(sort == .cpu ? .primary : .secondary)
                    Text(bytes(r.mem)).frame(width: 72, alignment: .trailing)
                        .foregroundStyle(sort == .mem ? .primary : .secondary)
                    Text(rate(r.disk)).frame(width: 80, alignment: .trailing)
                        .foregroundStyle(sort == .disk ? .primary : .secondary)
                    Text(r.conns > 0 ? "\(r.conns)" : "–").frame(width: 46, alignment: .trailing)
                        .foregroundStyle(sort == .conn ? .primary : .secondary)
                }
                .font(.system(size: 11.5)).monospacedDigit()
            } else {
                Text(value).font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                    .foregroundStyle(valueColor)
            }
            Button { showConns.toggle() } label: {
                Image(systemName: "network").font(.system(size: 12))
                    .foregroundStyle(hover || showConns ? Color.accentColor : Color.secondary.opacity(0.0))
            }
            .buttonStyle(.plain)
            .help("查看 \(r.name) 的网络连接")
            .disabled(!(hover || showConns))
            .popover(isPresented: $showConns, arrowEdge: .trailing) {
                ConnectionsView(m: m, dns: m.dns, name: r.name, path: r.path, pids: r.pids)
            }
            Button { m.kill(r.name, r.pids) } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 13))
                    .foregroundStyle(hover ? Color.red.opacity(0.85) : Color.secondary.opacity(0.0))
            }
            .buttonStyle(.plain)
            .help(r.count > 1 ? "结束 \(r.name) 的全部 \(r.count) 个进程" : "结束 \(r.name)")
            .disabled(!hover)
        }
        .padding(.horizontal, 8).padding(.vertical, wide ? 5 : 4)
        .background(hover ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }

    private var value: String {
        switch sort {
        case .cpu: return String(format: "%.1f%%", r.pct)
        case .mem: return bytes(r.mem)
        case .disk: return rate(r.disk)
        case .conn: return r.conns > 0 ? "\(r.conns) 个连接" : (r.listens > 0 ? "监听 \(r.listens)" : "–")
        }
    }

    private var valueColor: Color {
        switch sort {
        case .cpu: return r.pct >= 100 ? .red : (r.pct >= 50 ? .orange : .primary)
        case .mem: return r.mem >= 2 << 30 ? .red : (r.mem >= 1 << 30 ? .orange : .primary)
        case .disk: return r.disk >= 50 * 1048576 ? .orange : .primary
        case .conn: return r.conns >= 500 ? .red : (r.conns >= 100 ? .orange : .primary)
        }
    }
}

struct SectionTitle: View {
    let t: String
    init(_ t: String) { self.t = t }
    var body: some View {
        Text(t).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 2)
    }
}

// MARK: - 顶部 / 底部

struct HeaderView: View {
    let s: Snapshot
    let paused: Bool
    var body: some View {
        let (h, msg) = s.health
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high)
                .frame(width: 36, height: 36)
                .padding(-3)
            VStack(alignment: .leading, spacing: 1) {
                Text("MacMon").font(.system(size: 14, weight: .semibold))
                Text(paused ? "监控已暂停" : msg).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if s.thermal != .nominal {
                Label(s.thermal == .fair ? "微热" : "过热", systemImage: "thermometer.medium")
                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(s.thermal == .fair ? .orange : .red)
            }
            HStack(spacing: 4) {
                Circle().fill(paused ? Color.gray : h.color).frame(width: 7, height: 7)
                Text(paused ? "已暂停" : (h == .good ? "良好" : h == .warn ? "注意" : "紧张"))
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background((paused ? Color.gray : h.color).opacity(0.14), in: Capsule())
        }
    }
}

struct FooterView: View {
    @ObservedObject var m: Model
    var showWindowButton = true
    var body: some View {
        HStack(spacing: 12) {
            Text(String(format: "MacMon 自身 %.1f%% CPU · %@ · 采样 %.1f ms", m.snap.me.cpuPct, bytes(m.snap.me.footprint), m.snap.me.tickMs))
                .font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
                .help("看门狗守护中：MacMon 自身卡住超过 20 秒会自动重启")
            Spacer()
            if showWindowButton {
                Button { m.openWindow() } label: { Image(systemName: "macwindow") }.help("打开监控窗口")
            }
            Button { m.openSettings() } label: { Image(systemName: "gearshape") }.help("设置")
            Menu {
                Button(m.paused ? "恢复监控" : "暂停监控") { m.togglePause() }
                Toggle("守护模式（开机自启 + 卡死自动重启）", isOn: Binding(get: { m.agentOn }, set: { _ in m.toggleAgent() }))
                Divider()
                Button("发送测试通知") { m.testNotify() }
                Button("在访达中显示日志") { m.revealLog() }
                Divider()
                Button("退出 MacMon") { m.quit() }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
    }
}

// MARK: - 菜单栏弹窗

struct PopoverView: View {
    @ObservedObject var m: Model
    @AppStorage("popoverSort") private var sortRaw = SortKey.cpu.rawValue

    var body: some View {
        let s = m.snap
        let sort = SortKey(rawValue: sortRaw) ?? .cpu
        VStack(alignment: .leading, spacing: 12) {
            HeaderView(s: s, paused: m.paused)
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow { CPUCard(s: s); MemCard(s: s) }
                GridRow { netCard(s); ioCard(s) }
            }
            VolumesView(vols: s.volumes)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    SectionTitle("应用")
                    Spacer()
                    Picker("", selection: $sortRaw) {
                        ForEach(SortKey.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200).controlSize(.small)
                }
                Card {
                    VStack(spacing: 0) {
                        ForEach(items(s, byApp: true, sort: sort, limit: 6)) { AppRow(m: m, r: $0, sort: sort) }
                    }
                    .padding(-6)
                }
            }
            Divider().opacity(0.5)
            FooterView(m: m)
        }
        .padding(14)
        .frame(width: 400)
    }
}

// MARK: - 监控窗口

struct DashboardView: View {
    @ObservedObject var m: Model
    @AppStorage("dashSort") private var sortRaw = SortKey.cpu.rawValue
    @AppStorage("dashByApp") private var byApp = true

    var body: some View {
        let s = m.snap
        let sort = SortKey(rawValue: sortRaw) ?? .cpu
        VStack(alignment: .leading, spacing: 14) {
            HeaderView(s: s, paused: m.paused)
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow { CPUCard(s: s, tall: true); MemCard(s: s, tall: true) }
                GridRow { netCard(s, tall: true); ioCard(s, tall: true) }
            }
            HStack(alignment: .top, spacing: 12) {
                VolumesView(vols: s.volumes).frame(width: 300)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Picker("", selection: $byApp) {
                            Text("应用").tag(true)
                            Text("进程").tag(false)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 110).controlSize(.small)
                        Spacer()
                        Picker("", selection: $sortRaw) {
                            ForEach(SortKey.allCases) { Text("按\($0.rawValue)").tag($0.rawValue) }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 250).controlSize(.small)
                    }
                    Card {
                        VStack(spacing: 0) {
                            HStack(spacing: 8) {
                                Text("名称").padding(.leading, 30)
                                Spacer()
                                Text(byApp ? "进程" : "PID").frame(width: 60, alignment: .trailing)
                                Text("CPU").frame(width: 64, alignment: .trailing)
                                Text("内存").frame(width: 72, alignment: .trailing)
                                Text("磁盘").frame(width: 80, alignment: .trailing)
                                Text("连接").frame(width: 46, alignment: .trailing)
                                Color.clear.frame(width: 12, height: 1)
                                Color.clear.frame(width: 13, height: 1)
                            }
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.bottom, 4)
                            Divider().opacity(0.5)
                            ScrollView {
                                LazyVStack(spacing: 0) {
                                    ForEach(items(s, byApp: byApp, sort: sort, limit: 40)) {
                                        AppRow(m: m, r: $0, sort: sort, wide: true)
                                    }
                                }
                            }
                        }
                        .padding(-6)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            FooterView(m: m, showWindowButton: false)
        }
        .padding(18)
        .padding(.top, 14)
        .frame(minWidth: 900, minHeight: 760)
        .background(VisualEffect().ignoresSafeArea())
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - 设置

struct SettingsView: View {
    @ObservedObject var m: Model
    @AppStorage(K.cpu) private var cpu = 85.0
    @AppStorage(K.cpuSustainSec) private var cpuSec = 30.0
    @AppStorage(K.mem) private var mem = 92.0
    @AppStorage(K.availMB) private var avail = 200.0
    @AppStorage(K.swapGrowMB) private var swap = 512.0
    @AppStorage(K.procCpu) private var procCpu = 60.0
    @AppStorage(K.appCpu) private var appCpu = 100.0
    @AppStorage(K.appSustainSec) private var appSec = 60.0
    @AppStorage(K.appConn) private var appConn = 500.0
    @AppStorage(K.cooldownMin) private var cooldown = 10.0
    @AppStorage(K.soundOn) private var sound = true
    @AppStorage(AK.on) private var akOn = false
    @AppStorage(AK.list) private var akList = ""
    @AppStorage(AK.cpu) private var akCpu = 200.0
    @AppStorage(AK.cpuSec) private var akCpuSec = 180.0
    @AppStorage(AK.memGB) private var akMem = 3.0
    @State private var typed = ""

    private var akNames: [String] {
        akList.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func akAdd(_ n: String) {
        let n = n.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !akNames.contains(n), !AK.neverKill.contains(n) else { return }
        akList = (akNames + [n]).joined(separator: "\n")
    }

    private func akRemove(_ n: String) {
        akList = akNames.filter { $0 != n }.joined(separator: "\n")
    }

    /// 可加入名单的：正在运行、是真正的 .app、不在禁止名单、还没加
    private var akCandidates: [AppUsage] {
        m.snap.apps.filter { $0.appPath != nil && !AK.neverKill.contains($0.name) && !akNames.contains($0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section("系统") {
                num("CPU 占用超过", $cpu, "%")
                num("持续", $cpuSec, "秒后提醒")
                num("内存占用超过", $mem, "%（且系统有内存压力）")
                num("可用内存低于", $avail, "MB")
                num("Swap 3 秒内增长超过", $swap, "MB")
            }
            Section("应用与进程") {
                num("单个应用合计 CPU 超过", $appCpu, "%（100% = 1 个核）")
                num("持续", $appSec, "秒后提醒")
                num("单个进程 CPU 超过", $procCpu, "%（持续 3 分钟）")
                num("单个应用网络连接超过", $appConn, "个")
            }
            Section("通知") {
                num("同类提醒间隔", $cooldown, "分钟")
                Toggle("提示音", isOn: $sound)
            }
            Section {
                Toggle(isOn: $akOn) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("自动结束失控应用")
                        Text("只处理下面名单里的应用，而且要系统真的卡住时才动手").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if akOn {
                    if akNames.isEmpty {
                        Text("名单为空：不会自动结束任何应用").font(.caption).foregroundStyle(.orange)
                    }
                    ForEach(akNames, id: \.self) { n in
                        HStack(spacing: 8) {
                            AppIcon(m: m, path: m.snap.apps.first { $0.name == n }?.appPath, size: 18)
                            Text(n)
                            Spacer()
                            Button { akRemove(n) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                                .buttonStyle(.borderless).help("移出名单")
                        }
                    }
                    HStack {
                        Menu("添加正在运行的应用") {
                            ForEach(akCandidates, id: \.name) { a in Button(a.name) { akAdd(a.name) } }
                        }
                        .fixedSize()
                        TextField("", text: $typed, prompt: Text("或输入应用名"))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { akAdd(typed); typed = "" }
                    }
                    num("应用合计 CPU 超过", $akCpu, "%（200% = 2 核）")
                    num("且持续", $akCpuSec, "秒")
                    num("或系统内存告急时应用占用超过", $akMem, "GB")
                    Text("同时满足才会动手：系统真的卡（整机 CPU ≥ 80%，或内存压力严重）· 不是你正在用的前台应用 · 距上次自动结束已超过 10 分钟。会先请求正常退出，5 秒后仍未退出才强制结束，事后通知你。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } header: { Text("自动处理") }
            Section {
                Toggle(isOn: Binding(get: { m.agentOn }, set: { _ in m.toggleAgent() })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("守护模式")
                        Text("开机自动启动；MacMon 崩溃或卡住时自动重启").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("运行") }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func num(_ label: String, _ v: Binding<Double>, _ unit: String) -> some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                TextField("", value: v, format: .number)
                    .multilineTextAlignment(.trailing).frame(width: 64).textFieldStyle(.roundedBorder)
                Text(unit).foregroundStyle(.secondary).frame(minWidth: 0, alignment: .leading)
            }
        }
    }
}

// MARK: - 网络连接明细

struct ConnGroup: Identifiable {
    let id: String
    let proto: String
    let remote: String
    let port: UInt16
    let state: String
    let count: Int
}

struct ConnectionsView: View {
    @ObservedObject var m: Model
    @ObservedObject var dns: HostResolver
    let name: String
    let path: String?
    let pids: [pid_t]
    @State private var conns: [Conn] = []
    @State private var loaded = false
    var scrolls = true

    init(m: Model, dns: HostResolver, name: String, path: String?, pids: [pid_t], initial: [Conn]? = nil) {
        self.m = m; self.dns = dns; self.name = name; self.path = path; self.pids = pids
        scrolls = initial == nil
        _conns = State(initialValue: initial ?? [])
        _loaded = State(initialValue: initial != nil)
    }

    var body: some View {
        let active = conns.filter { !$0.listening && !$0.remote.isEmpty }
        let listens = Dictionary(grouping: conns.filter { $0.listening }, by: { "\($0.proto)-\($0.lport)-\($0.local)" })
            .values.compactMap { $0.first }.sorted { $0.lport < $1.lport }
        let groups = Dictionary(grouping: active, by: { "\($0.proto)|\($0.remote)|\($0.rport)" })
            .map { k, v in ConnGroup(id: k, proto: v[0].proto, remote: v[0].remote, port: v[0].rport,
                                     state: v.contains { $0.state == "已连接" } ? "已连接" : v[0].state, count: v.count) }
            .sorted { ($0.count, $0.remote) > ($1.count, $1.remote) }
        let viaProxy = active.contains { HostResolver.isProxyFakeIP($0.remote) }

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AppIcon(m: m, path: path, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 13, weight: .semibold))
                    Text(loaded ? "\(active.count) 个连接 · \(groups.count) 个远端 · \(listens.count) 个监听端口" : "读取中…")
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
            }
            if viaProxy {
                Label("经代理（TUN 虚拟 IP 198.18.x.x），真实域名只有代理软件知道", systemImage: "arrow.triangle.branch")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            let list = VStack(alignment: .leading, spacing: 12) {
                    if !groups.isEmpty {
                        section("远端") {
                            ForEach(groups) { g in remoteRow(g) }
                        }
                    }
                    if !listens.isEmpty {
                        section("监听端口") {
                            ForEach(listens) { c in listenRow(c) }
                        }
                    }
                    if loaded && groups.isEmpty && listens.isEmpty {
                        Text("当前没有网络连接").font(.system(size: 12)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 20)
                    }
                }
            if scrolls { ScrollView { list }.frame(maxHeight: 380) } else { list }
        }
        .padding(14)
        .frame(width: 440)
        .task {
            // 打开期间每 3 秒刷新；关闭弹窗即停止
            while !Task.isCancelled {
                let r = await m.loadConns(pids)
                conns = r
                loaded = true
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func section<C: View>(_ t: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            VStack(spacing: 0) { c() }
                .padding(4)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    private func remoteRow(_ g: ConnGroup) -> some View {
        let fake = HostResolver.isProxyFakeIP(g.remote)
        let host = fake ? nil : dns.host(g.remote)
        return HStack(spacing: 8) {
            Image(systemName: fake ? "arrow.triangle.branch" : (HostResolver.isPrivate(g.remote) ? "house" : "globe"))
                .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(host ?? (fake ? "代理虚拟地址" : g.remote)).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Text(host != nil || fake ? g.remote : (HostResolver.isPrivate(g.remote) ? "局域网 / 本机" : "未解析到域名"))
                    .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
            .textSelection(.enabled)
            Spacer(minLength: 6)
            Text(":\(g.port)\(serviceName(g.port).map { " " + $0 } ?? "")").font(.system(size: 11)).foregroundStyle(.secondary)
            Text(g.proto).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 4).padding(.vertical, 1).background(Color.secondary.opacity(0.12), in: Capsule())
            Text(g.count > 1 ? "×\(g.count)" : " ").font(.system(size: 11, weight: .medium)).monospacedDigit().frame(width: 32, alignment: .trailing)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .help(g.state)
    }

    private func listenRow(_ c: Conn) -> some View {
        let anyIf = c.local.isEmpty || c.local == "0.0.0.0" || c.local == "::"
        let localOnly = c.local.hasPrefix("127.") || c.local == "::1"
        return HStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
            Text("\(c.proto) \(c.lport)").font(.system(size: 12)).monospacedDigit()
            if let s = serviceName(c.lport) { Text(s).font(.system(size: 10.5)).foregroundStyle(.secondary) }
            Spacer()
            Text(localOnly ? "仅本机" : (anyIf ? "局域网可访问" : c.local))
                .font(.system(size: 10.5, weight: anyIf ? .medium : .regular))
                .foregroundStyle(anyIf ? Color.orange : Color.secondary)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .help(anyIf ? "监听所有网卡：同一局域网的设备可以连到这个端口" : "")
    }
}
