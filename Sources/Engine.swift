// macmon — 报警引擎（App 与 CLI 共用）
import Foundation
import Darwin

// MARK: - 报警引擎（非线程安全：只能在一个串行队列里使用）

final class Engine {
    var cfg: Config
    var onSample: ((String) -> Void)? = nil
    let onAlert: (_ category: String, _ title: String, _ body: String) -> Void

    private var prevProcs: [pid_t: ProcSample] = [:]
    private var prevWall: Date? = nil
    private var prevSwapUsed: UInt64? = nil
    private var prevSwapIn: UInt64? = nil
    private var prevSwapOut: UInt64? = nil
    private var cpuStrikes = 0
    private var cooldowns: [String: Date] = [:]
    private var hogPid: pid_t? = nil
    private var hogSince: Date? = nil
    private var appHogSince: [String: Date] = [:]
    private var sampleCount = 0
    private(set) var lastApps: [AppUsage] = []

    init(cfg: Config, onAlert: @escaping (_ category: String, _ title: String, _ body: String) -> Void) {
        self.cfg = cfg
        self.onAlert = onAlert
    }

    // 单周期进程 CPU%（按累计 CPU 时间差分）
    func procCPUs(_ procs: [ProcSample], wall: Date, conns: [pid_t: ConnCount] = [:]) -> [ProcCPU] {
        defer {
            prevWall = wall
            prevProcs = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        }
        guard let pw = prevWall else { return [] }
        let dt = wall.timeIntervalSince(pw)
        guard dt >= 0.2 else { return [] }
        let me = getpid()
        var list: [ProcCPU] = []
        list.reserveCapacity(procs.count)
        for p in procs where p.pid != me {
            if let prev = prevProcs[p.pid], p.cpuNs >= prev.cpuNs {
                let v = Double(p.cpuNs - prev.cpuNs) / 1_000_000_000.0 / dt * 100.0
                let io = (p.diskR >= prev.diskR ? p.diskR - prev.diskR : 0)
                       + (p.diskW >= prev.diskW ? p.diskW - prev.diskW : 0)
                let cc = conns[p.pid]
                list.append(ProcCPU(p: p, pct: max(0, v), diskRate: Double(io) / dt,
                                    conns: cc?.active ?? 0, listens: cc?.listening ?? 0))
            }
        }
        return list.sorted { $0.pct > $1.pct }
    }

    private func canAlert(_ key: String) -> Bool {
        let now = Date()
        if let last = cooldowns[key], now.timeIntervalSince(last) < cfg.cooldown { return false }
        cooldowns[key] = now
        if cooldowns.count > 200 {   // 防止 key 无限增长
            cooldowns = cooldowns.filter { now.timeIntervalSince($0.value) < cfg.cooldown }
        }
        return true
    }

    private func alert(_ category: String, _ title: String, _ body: String) {
        onAlert(category, title, body)
    }

    private func topAppsLine(byMem: Bool, _ n: Int = 3) -> String {
        let arr = byMem ? lastApps.sorted { $0.mem > $1.mem } : lastApps
        return arr.prefix(n).map {
            byMem ? "\($0.name) \(bytes($0.mem))" : "\($0.name) \(String(format: "%.0f%%", $0.pct))"
        }.joined(separator: "、")
    }

    /// 内核发出的内存压力事件（比自己算的阈值更权威）
    func kernelPressure(critical: Bool) {
        guard canAlert(critical ? "kpressure.crit" : "kpressure.warn") else { return }
        let title = critical ? "🚨 系统内存压力：严重" : "😰 系统内存压力：警告"
        var b = critical ? "macOS 判定内存已严重不足，马上会明显卡顿。" : "macOS 判定内存紧张，开始压缩/换页。"
        let top = topAppsLine(byMem: true)
        if !top.isEmpty { b += "\n内存大户：\(top)" }
        alert(critical ? "kpressure.crit" : "kpressure.warn", title, b)
    }

    func evaluate(cpu: CPUSnap?, mem: MemSnap?, procList: [ProcCPU], wall: Date) {
        sampleCount += 1
        lastApps = groupByApp(procList)

        if let cb = onSample {
            var s = "采样#\(sampleCount)"
            if let c = cpu {
                s += " | cpu 忙\(pct(100 - c.idle)) 用\(pct(c.user)) 系\(pct(c.sys))"
            }
            if let m = mem {
                s += " | 内存 \(bytes(m.used))/\(bytes(m.total)) 可用 \(bytes(m.avail))"
                if m.swapTotal > 0 { s += " | swap \(bytes(m.swapUsed))/\(bytes(m.swapTotal))" }
            }
            if let top = lastApps.first { s += " | top \(top.name)×\(top.pids.count) \(pct(top.pct))" }
            cb(s)
        }

        // 1) 系统级 CPU 持续高占用
        if let c = cpu {
            let busy = 100 - c.idle
            if busy >= cfg.cpuThreshold { cpuStrikes += 1 } else { cpuStrikes = 0 }
            if cpuStrikes >= cfg.cpuSustained, canAlert("cpu") {
                var b = "忙碌 \(pct(busy))（用户 \(pct(c.user)) / 系统 \(pct(c.sys))），已持续约 \(Int(Double(cpuStrikes) * cfg.interval)) 秒"
                let top = topAppsLine(byMem: false)
                let appsSum = lastApps.reduce(0) { $0 + $1.pct } / Double(ProcessInfo.processInfo.activeProcessorCount)
                if c.sys >= 50 && appsSum < busy / 2 {
                    // 系统态极高但找不到哪个应用在吃 → 内核在疯狂换页/压缩内存
                    b += "\n⚠️ CPU 主要耗在内核（系统态），不是某个应用在算，而是内存不足导致疯狂换页。请关掉内存大户：\(topAppsLine(byMem: true))"
                } else if !top.isEmpty {
                    b += "\n大户：\(top)"
                }
                if let m = mem, m.swapTotal > 0 { b += "\nSwap \(bytes(m.swapUsed))/\(bytes(m.swapTotal))" }
                alert("cpu", "🥵 CPU 持续高占用", b)
            }
        }

        // 2) 单进程持续吃 CPU
        if let top = procList.first(where: { $0.pct >= cfg.procCpuThreshold }) {
            if hogPid == top.p.pid, let since = hogSince {
                if wall.timeIntervalSince(since) >= cfg.procSustainSec {
                    if canAlert("hog.\(top.p.pid)") {
                        alert("hog", "🔥 进程占用过高",
                              "\(top.p.name)（pid \(top.p.pid)）已持续占用 \(pct(top.pct)) CPU 超过 \(Int(cfg.procSustainSec / 60)) 分钟\n点菜单栏 MacMon 可一键结束")
                    }
                    hogSince = wall
                }
            } else {
                hogPid = top.p.pid
                hogSince = wall
            }
        } else {
            hogPid = nil
            hogSince = nil
        }

        // 3) 应用级（合并全部 Helper）持续吃 CPU —— 专治 Electron / Chrome
        var stillHot = Set<String>()
        for a in lastApps where a.pct >= cfg.appCpuThreshold {
            stillHot.insert(a.name)
            let since = appHogSince[a.name] ?? wall
            appHogSince[a.name] = since
            if wall.timeIntervalSince(since) >= cfg.appSustainSec, canAlert("apphog.\(a.name)") {
                alert("apphog", "🔥 \(a.name) 持续吃 CPU",
                      "\(a.name) 共 \(a.pids.count) 个进程合计占用 \(String(format: "%.0f%%", a.pct)) CPU（≈\(String(format: "%.1f", a.pct / 100)) 个核），已超过 \(Int(cfg.appSustainSec)) 秒\n点菜单栏 MacMon 可一键结束")
            }
        }
        appHogSince = appHogSince.filter { stillHot.contains($0.key) }

        // 4) 内存不足 + swap 暴涨 + 单应用内存过大
        if let m = mem {
            let usedPct = Double(m.used) / Double(m.total) * 100.0
            let availMB = Double(m.avail) / 1048576.0
            if (usedPct >= cfg.memThreshold && m.pressure != .normal) || availMB <= cfg.availMinMB {
                if canAlert("mem") {
                    var b = "已用 \(pct(usedPct))（\(bytes(m.used)) / \(bytes(m.total))），可用 \(bytes(m.avail))"
                    if m.swapTotal > 0 { b += "，Swap \(bytes(m.swapUsed)) / \(bytes(m.swapTotal))" }
                    let top = topAppsLine(byMem: true)
                    if !top.isEmpty { b += "\n内存大户：\(top)" }
                    alert("mem", "😰 内存吃紧", b)
                }
            }
            if let prevS = prevSwapUsed {
                let dMB = (Double(m.swapUsed) - Double(prevS)) / 1048576.0
                if dMB >= cfg.swapGrowMB, canAlert("swap") {
                    var b = "本周期（\(Int(cfg.interval))s）swap 增加 \(Int(dMB))MB，现 \(bytes(m.swapUsed))。内存严重不足，系统正在卡顿！"
                    if let pi = prevSwapIn, let po = prevSwapOut,
                       m.swapOuts >= po, m.swapIns >= pi {
                        let outMBps = Double(m.swapOuts - po) * Double(hostPageSize()) / cfg.interval / 1048576.0
                        let inMBps = Double(m.swapIns - pi) * Double(hostPageSize()) / cfg.interval / 1048576.0
                        b += String(format: " 换页速率：出 %.0fMB/s 入 %.0fMB/s", outMBps, inMBps)
                    }
                    alert("swap", "🚨 Swap 暴涨", b)
                }
            }
            prevSwapUsed = m.swapUsed
            prevSwapIn = m.swapIns
            prevSwapOut = m.swapOuts

            let limit = UInt64(Double(m.total) * cfg.appMemFraction)
            for a in lastApps where a.mem >= limit {
                if canAlert("appmem.\(a.name)") {
                    alert("appmem", "🐘 \(a.name) 占用内存过大",
                          "\(a.name) 共 \(a.pids.count) 个进程合计占用 \(bytes(a.mem))（物理内存 \(bytes(m.total)) 的 \(Int(Double(a.mem) / Double(m.total) * 100))%）")
                }
            }
        }

        // 5) 单应用网络连接异常多（连接泄漏 / 疯狂发请求）
        for a in lastApps where Double(a.conns) >= cfg.appConnThreshold {
            if canAlert("appconn.\(a.name)") {
                alert("appconn", "🌐 \(a.name) 网络连接异常多",
                      "\(a.name) 当前有 \(a.conns) 个网络连接，可能在疯狂发请求或连接泄漏。\n点菜单栏 MacMon → 应用旁的 ⓘ 查看它在连哪些地址")
            }
        }

        // 6) 磁盘
        if let d = diskFree(), d.freeGB <= cfg.diskMinGB, canAlert("disk") {
            alert("disk", "💾 磁盘空间不足", String(format: "根分区剩余 %.1f GB（共 %.0f GB）", d.freeGB, d.totalGB))
        }
    }
}
