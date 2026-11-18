// macmon CLI — CPU / 内存 / Swap 监控命令行版（与 App 共享 Sources/MonitorCore.swift）
import Foundation
import Darwin

func sendNotification(_ title: String, _ body: String, sound: String) {
    var script = "display notification \"\(esc(body))\" with title \"\(esc(title))\""
    if !sound.isEmpty && sound != "off" {
        script += " sound name \"\(esc(sound))\""
    }
    sh("/usr/bin/osascript", ["-e", script])
}


func cmdRun(_ rest: ArraySlice<String>) {
    var cfg = Config()
    parseFlags(rest, &cfg)

    // 防止双开
    let home = FileManager.default.homeDirectoryForCurrentUser
    let pidURL = home.appendingPathComponent(".macmon/macmon.pid")
    try? FileManager.default.createDirectory(at: pidURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let data = try? Data(contentsOf: pidURL),
       let s = String(data: data, encoding: .utf8), let old = pid_t(s),
       old != getpid(), kill(old, 0) == 0 {
        out("macmon 已在运行（pid \(old)），退出。如需重启：macmon uninstall && macmon install")
        exit(0)
    }
    try? "\(getpid())".write(to: pidURL, atomically: true, encoding: .utf8)

    let logger = Logger(path: cfg.logPath.map(expandPath))
    logger.write("macmon \(VERSION) 启动：间隔 \(cfg.interval)s，CPU> \(cfg.cpuThreshold)%×\(cfg.cpuSustained)次，内存> \(cfg.memThreshold)%，单进程> \(cfg.procCpuThreshold)%×\(Int(cfg.procSustainSec))s，通知=\(cfg.notify)")

    signal(SIGPIPE, SIG_IGN)
    let engine = Engine(cfg: cfg) { category, title, body in
        logger.write("⚠️ \(title) — \(body.replacingOccurrences(of: "\n", with: " / "))")
        if cfg.notify { sendNotification(title, body, sound: cfg.sound) }
    }
    engine.onSample = cfg.logSamples ? { logger.write($0) } : nil
    let sampler = CPUSampler()

    while true {
        let wall = Date()
        let cpu = sampler.sample()
        let mem = memSample()
        let procs = sampleProcs()
        let pc = engine.procCPUs(procs, wall: wall)
        engine.evaluate(cpu: cpu, mem: mem, procList: pc, wall: wall)
        let elapsed = Date().timeIntervalSince(wall)
        Thread.sleep(forTimeInterval: max(0.5, cfg.interval - elapsed))
    }
}

// MARK: - status / top 命令

struct StatusData {
    var cpu: CPUSnap?
    var load: (Double, Double, Double)?
    var cores: Int
    var mem: MemSnap?
    var procCPUs: [ProcCPU]
    var disk: (freeGB: Double, totalGB: Double)?
}

func collectStatus(window: Double) -> StatusData {
    let sampler = CPUSampler()
    _ = sampler.sample()
    var procsA = sampleProcs()
    let tA = Date()
    Thread.sleep(forTimeInterval: window)
    let cpu = sampler.sample()
    let procsB = sampleProcs()
    let tB = Date()
    let dt = max(0.2, tB.timeIntervalSince(tA))

    let prev: [pid_t: ProcSample] = Dictionary(procsA.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
    procsA = []
    let me = getpid()
    var pc: [ProcCPU] = []
    for p in procsB where p.pid != me {
        guard let prevNs = prev[p.pid]?.cpuNs, p.cpuNs >= prevNs else { continue }
        let v = Double(p.cpuNs - prevNs) / 1_000_000_000.0 / dt * 100.0
        pc.append(ProcCPU(p: p, pct: max(0, v), diskRate: 0))
    }
    pc.sort { $0.pct > $1.pct }

    return StatusData(cpu: cpu, load: loadAvg(), cores: ProcessInfo.processInfo.activeProcessorCount,
                      mem: memSample(), procCPUs: pc, disk: diskFree())
}

func cmdStatus(_ rest: ArraySlice<String>) {
    var cfg = Config()
    parseFlags(rest, &cfg)
    let d = collectStatus(window: 1.0)

    out("━━━━━━━━ macmon 系统快照 \(iso.string(from: Date())) ━━━━━━")
    if let c = d.cpu {
        out(String(format: "CPU  忙碌 %.1f%%（用户 %.1f%% / 系统 %.1f%%）｜空闲 %.1f%%",
                   100 - c.idle, c.user, c.sys, c.idle))
    }
    if let l = d.load {
        out(String(format: "     负载 %.1f / %.1f / %.1f（核心 %d）", l.0, l.1, l.2, d.cores))
    }
    if let m = d.mem {
        let usedPct = Double(m.used) / Double(m.total) * 100
        out(String(format: "内存 已用 %@ / %@（%.1f%%）｜可用 %@｜压缩 %@｜联动 %@",
                   bytes(m.used), bytes(m.total), usedPct, bytes(m.avail), bytes(m.compressed), bytes(m.wired)))
        if m.swapTotal > 0 {
            out(String(format: "Swap 已用 %@ / %@（%.0f%%）", bytes(m.swapUsed), bytes(m.swapTotal),
                       Double(m.swapUsed) / Double(m.swapTotal) * 100))
        }
    }
    if let dsk = d.disk {
        out(String(format: "磁盘 /  剩余 %.1fGB（共 %.0fGB）", dsk.freeGB, dsk.totalGB))
    }

    out("")
    out("占用 CPU 最高的进程（1 秒窗口）：")
    for (i, t) in d.procCPUs.prefix(cfg.topN).enumerated() {
        out(String(format: "  %d. %6.1f%%  pid %-7d %@", i + 1, t.pct, t.p.pid, t.p.name))
    }
    if d.mem != nil {
        let topMem = d.procCPUs.sorted { $0.p.mem > $1.p.mem }
        out("占用内存最多的进程：")
        for (i, t) in topMem.prefix(cfg.topN).enumerated() {
            out(String(format: "  %d. %8@  pid %-7d %@", i + 1, bytes(t.p.mem), t.p.pid, t.p.name))
        }
    }

    out("")
    out("诊断：")
    var tips = 0
    if let c = d.cpu {
        let busy = 100 - c.idle
        if busy >= 85 {
            tips += 1
            out(String(format: "  ❌ CPU 基本打满（忙 %.1f%%，系统态 %.1f%%）。系统态过高常见于 swap 疯狂换页或内核任务", busy, c.sys))
        } else if busy >= 60 {
            tips += 1
            out("  ⚠️ CPU 占用偏高")
        }
    }
    if let l = d.load, Double(l.0) > Double(d.cores) * 2 {
        tips += 1
        out(String(format: "  ❌ 负载 %.1f 远超核心数 %d，系统严重过载", l.0, d.cores))
    }
    if let m = d.mem {
        let usedPct = Double(m.used) / Double(m.total) * 100
        let availMB = Double(m.avail) / 1048576
        if availMB < 300 {
            tips += 1
            out(String(format: "  ❌ 可用内存仅 %.0fMB — 即将/正在卡顿", availMB))
        } else if usedPct >= 90 {
            tips += 1
            out("  ⚠️ 内存几乎用满")
        }
        if m.swapTotal > 0, Double(m.swapUsed) / Double(m.swapTotal) >= 0.5 {
            tips += 1
            out("  ❌ Swap 用量过半 — 内存严重不足，这是卡顿主因")
        }
    }
    if let dsk = d.disk, dsk.freeGB < 20 {
        tips += 1
        out(String(format: "  ⚠️ 磁盘剩余 %.1fGB", dsk.freeGB))
    }
    if tips == 0 { out("  ✅ 看起来正常") }
}

func cmdTop(_ rest: ArraySlice<String>) {
    var cfg = Config()
    var by = "cpu"
    var arr = Array(rest)
    if let i = arr.firstIndex(of: "--by"), i + 1 < arr.count {
        by = arr[i + 1]
        arr.removeSubrange(i...i + 1)
    }
    parseFlags(arr[...], &cfg)
    let n = max(1, cfg.topN)

    let d = collectStatus(window: 1.0)
    out("macmon top（1 秒窗口）\(iso.string(from: Date()))")
    if by == "mem" {
        let sorted = d.procCPUs.sorted { $0.p.mem > $1.p.mem }
        out("内存       CPU%     PID  进程")
        for t in sorted.prefix(n) {
            out(String(format: "%-10@ %6.1f %7d  %@", bytes(t.p.mem), t.pct, t.p.pid, t.p.name))
        }
    } else {
        out("CPU%       内存     PID  进程")
        for t in d.procCPUs.prefix(n) {
            out(String(format: "%5.1f%% %10@ %7d  %@", t.pct, bytes(t.p.mem), t.p.pid, t.p.name))
        }
    }
}

// MARK: - install / uninstall（LaunchAgent）

func cfgFlags(_ cfg: Config) -> [String] {
    let d = Config()
    var a: [String] = []
    if cfg.interval != d.interval { a += ["--interval", String(cfg.interval)] }
    if cfg.cpuThreshold != d.cpuThreshold { a += ["--cpu-threshold", String(cfg.cpuThreshold)] }
    if cfg.cpuSustained != d.cpuSustained { a += ["--sustained", String(cfg.cpuSustained)] }
    if cfg.memThreshold != d.memThreshold { a += ["--mem-threshold", String(cfg.memThreshold)] }
    if cfg.availMinMB != d.availMinMB { a += ["--avail-mb", String(cfg.availMinMB)] }
    if cfg.swapGrowMB != d.swapGrowMB { a += ["--swap-grow-mb", String(cfg.swapGrowMB)] }
    if cfg.procCpuThreshold != d.procCpuThreshold { a += ["--proc-cpu", String(cfg.procCpuThreshold)] }
    if cfg.procSustainSec != d.procSustainSec { a += ["--proc-sustain-sec", String(cfg.procSustainSec)] }
    if cfg.diskMinGB != d.diskMinGB { a += ["--disk-min-gb", String(cfg.diskMinGB)] }
    if cfg.cooldown != d.cooldown { a += ["--cooldown", String(cfg.cooldown)] }
    if cfg.topN != d.topN { a += ["--top", String(cfg.topN)] }
    if cfg.logSamples { a += ["--log-samples"] }
    if !cfg.notify { a += ["--no-notify"] }
    if cfg.sound != d.sound { a += ["--sound", cfg.sound] }
    return a
}

let label = "com.ck.macmon"

func cmdInstall(_ rest: ArraySlice<String>) {
    var cfg = Config()
    parseFlags(rest, &cfg)
    let home = FileManager.default.homeDirectoryForCurrentUser
    let dir = home.appendingPathComponent(".macmon")
    let binDir = dir.appendingPathComponent("bin")
    try? FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

    // 把自己拷到稳定路径
    let src = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let dst = binDir.appendingPathComponent("macmon")
    if src.standardizedFileURL.path != dst.standardizedFileURL.path {
        try? FileManager.default.removeItem(at: dst)
        do {
            try FileManager.default.copyItem(at: src, to: dst)
        } catch {
            FileHandle.standardError.write(Data("复制二进制失败：\(error)\n".utf8))
            exit(1)
        }
    }
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)

    let logPath = dir.appendingPathComponent("macmon.log").path

    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key><string>\(label)</string>
        <key>ProgramArguments</key>
        <array>
            <string>\(dst.path)</string>
            <string>run</string>
            <string>--log</string>
            <string>\(logPath)</string>
    \(cfgFlags(cfg).map { "<string>" + escXML($0) + "</string>" }.joined(separator: "\n"))
        </array>
        <key>RunAtLoad</key><true/>
        <key>KeepAlive</key><true/>
        <key>ProcessType</key><string>Background</string>
        <key>StandardOutPath</key><string>\(dir.appendingPathComponent("launchd.out.log").path)</string>
        <key>StandardErrorPath</key><string>\(dir.appendingPathComponent("launchd.err.log").path)</string>
    </dict>
    </plist>
    """

    let plistPath = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    try? FileManager.default.createDirectory(at: plistPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? plist.write(toFile: plistPath.path, atomically: true, encoding: .utf8)

    let uid = getuid()
    sh("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])   // 忽略失败（可能本来没装）
    let rc = sh("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistPath.path])
    if rc != 0 {
        out("bootstrap 失败（rc=\(rc)），尝试旧版 load …")
        sh("/bin/launchctl", ["load", "-w", plistPath.path])
    }

    out("✅ 已安装并启动")
    out("   程序：\(dst.path)")
    out("   配置：\(plistPath.path)")
    out("   日志：\(logPath)（报警记录）")
    out("")
    out("常用命令：")
    out("  tail -f ~/.macmon/macmon.log      # 看日志")
    out("  macmon status                     # 当前系统快照")
    out("  macmon uninstall                  # 卸载")
}

func escXML(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

func cmdUninstall() {
    let uid = getuid()
    sh("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
    let home = FileManager.default.homeDirectoryForCurrentUser
    let plistPath = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    try? FileManager.default.removeItem(at: plistPath)
    try? FileManager.default.removeItem(at: home.appendingPathComponent(".macmon/bin/macmon"))
    try? FileManager.default.removeItem(at: home.appendingPathComponent(".macmon/macmon.pid"))
    out("✅ 已卸载（日志保留在 ~/.macmon/，可 rm -rf ~/.macmon 彻底清理）")
}

// MARK: - 参数解析

func parseFlags(_ a: ArraySlice<String>, _ cfg: inout Config) {
    var it = a.makeIterator()
    func v() -> String { it.next() ?? "" }
    while let f = it.next() {
        switch f {
        case "--interval":        cfg.interval = Double(v()) ?? cfg.interval
        case "--cpu-threshold":   cfg.cpuThreshold = Double(v()) ?? cfg.cpuThreshold
        case "--sustained":       cfg.cpuSustained = Int(v()) ?? cfg.cpuSustained
        case "--mem-threshold":   cfg.memThreshold = Double(v()) ?? cfg.memThreshold
        case "--avail-mb":        cfg.availMinMB = Double(v()) ?? cfg.availMinMB
        case "--swap-grow-mb":    cfg.swapGrowMB = Double(v()) ?? cfg.swapGrowMB
        case "--proc-cpu":        cfg.procCpuThreshold = Double(v()) ?? cfg.procCpuThreshold
        case "--proc-sustain-sec": cfg.procSustainSec = Double(v()) ?? cfg.procSustainSec
        case "--disk-min-gb":     cfg.diskMinGB = Double(v()) ?? cfg.diskMinGB
        case "--cooldown":        cfg.cooldown = Double(v()) ?? cfg.cooldown
        case "--top":             cfg.topN = Int(v()) ?? cfg.topN
        case "--log":             cfg.logPath = v()
        case "--log-samples":     cfg.logSamples = true
        case "--no-notify":       cfg.notify = false
        case "--sound":           cfg.sound = v()
        case "--no-sound":        cfg.sound = "off"
        default:
            FileHandle.standardError.write(Data("忽略未知参数：\(f)\n".utf8))
        }
    }
}

func printUsage() {
    out("""
    macmon \(VERSION) — macOS CPU / 内存 / Swap 监控 + 系统通知

    用法：
      macmon run [选项]          持续监控，超阈值发通知（建议配合 install 常驻）
      macmon status              打印当前系统资源快照 + 诊断
      macmon top [--by cpu|mem]  查看最吃资源的进程
      macmon install [选项]      安装 LaunchAgent：开机自启、崩溃自动拉起
      macmon uninstall           卸载 LaunchAgent
      macmon test-notify         发一条测试通知，确认通知通道正常

    run/install 选项：
      --interval 秒              采样间隔（默认 5）
      --cpu-threshold %          系统 CPU 忙碌阈值（默认 85）
      --sustained 次数           连续超标多少次才报警（默认 6 ≈ 30 秒）
      --mem-threshold %          内存已用阈值（默认 92）
      --avail-mb MB              可用内存下限（默认 200）
      --swap-grow-mb MB          单周期 swap 增长报警（默认 512）
      --proc-cpu %               单进程 CPU 阈值（默认 60）
      --proc-sustain-sec 秒      单进程持续时长（默认 180）
      --disk-min-gb GB           磁盘剩余空间报警（默认 10）
      --cooldown 秒              同类报警冷却（默认 600）
      --top N                    列表长度（默认 5）
      --log 路径                 追加写日志
      --log-samples              记录每次采样（默认只记报警）
      --no-notify                只记录不发通知
      --sound 名称 / --no-sound  通知音效（默认 Glass）
    """)
}
