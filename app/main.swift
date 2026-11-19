// MacMon.app — 菜单栏监控（与 CLI 共享 Sources/MonitorCore.swift）
//
// 自身防卡死机制：
//   • 所有采样都在后台串行队列（utility QoS）完成，主线程只负责刷 UI。
//   • 看门狗线程（最高 QoS，独立于主线程和采样队列）每 2 秒检查：
//       - 主线程心跳 > 20 秒没跳     → 判定 UI 卡死
//       - 采样队列 > 90 秒没完成一轮  → 判定采样卡死
//       - 自身内存 > 300MB            → 判定泄漏
//     任一命中 → 记录原因并立即重启自己（_exit，不走可能卡住的清理流程）。
//     看门狗自己若被系统饿死（醒来时间严重超时），只重置基线，不误杀。
//   • 守护模式：LaunchAgent + KeepAlive，进程崩溃/被杀/看门狗自杀后 launchd 自动拉起。
//   • 外部命令（launchctl）全部带超时且不在主线程执行。
//   • 关闭 App Nap，避免后台被系统节流导致监控延迟。
import AppKit
import UserNotifications
import ServiceManagement
import Darwin
import SwiftUI

let bundleID = "com.ck.macmon.app"
let agentLabel = "com.ck.macmon.app.agent"
let underAgent = ProcessInfo.processInfo.environment["MACMON_AGENT"] == "1"
let launchedAsRestart = CommandLine.arguments.contains("--restarted")
let showNoteName = Notification.Name("com.ck.macmon.show")
let preKillCategory = "macmon.prekill"
let keepActionID = "macmon.keep"
let macmonDir = expandPath("~/.macmon")
let restartMarker = macmonDir + "/last_restart.txt"
let agentPlistPath = expandPath("~/Library/LaunchAgents/\(agentLabel).plist")

// MARK: - 线程安全小工具

final class Atomic<T> {
    private var v: T
    private let l = NSLock()
    init(_ v: T) { self.v = v }
    var value: T {
        get { l.lock(); defer { l.unlock() }; return v }
        set { l.lock(); v = newValue; l.unlock() }
    }
}

// MARK: - 重启自己

/// 立即重启：守护模式下直接非零退出让 launchd 拉起；否则先拉起新实例再退出。
func restartSelf(reason: String) -> Never {
    try? FileManager.default.createDirectory(atPath: macmonDir, withIntermediateDirectories: true)
    try? "\(iso.string(from: Date()))  \(reason)".write(toFile: restartMarker, atomically: true, encoding: .utf8)
    if !underAgent {
        var pid: pid_t = 0
        let bundlePath = Bundle.main.bundlePath
        let argv: [String] = ["/usr/bin/open", "-n", bundlePath, "--args", "--restarted"]
        var cargs = argv.map { strdup($0) } + [nil]
        posix_spawn(&pid, "/usr/bin/open", nil, nil, &cargs, environ)
        cargs.forEach { free($0) }
    }
    _exit(3)
}

// MARK: - 看门狗

final class Watchdog {
    let mainBeat = Atomic(monoNow())
    let tickBeat = Atomic(monoNow())
    let mainLimit = 20.0
    let tickLimit = 90.0
    let memLimit: UInt64 = 300 * 1024 * 1024
    let lastCheck = Atomic(monoNow())

    func start() {
        // 主线程心跳：common 模式下菜单展开/模态弹窗时也照样跳
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.mainBeat.value = monoNow()
        }
        RunLoop.main.add(t, forMode: .common)

        let th = Thread { [weak self] in self?.loop() }
        th.name = "macmon.watchdog"
        th.qualityOfService = .userInteractive
        th.stackSize = 512 * 1024
        th.start()
    }

    private func loop() {
        var last = monoNow()
        while true {
            Thread.sleep(forTimeInterval: 2.0)
            let now = monoNow()
            lastCheck.value = now
            if now - last > 10 {
                // 看门狗自己被饿了 >10 秒：整机都卡，别误判自己，重置基线
                mainBeat.value = now
                tickBeat.value = now
                last = now
                continue
            }
            last = now
            let m = now - mainBeat.value
            if m > mainLimit { restartSelf(reason: "主线程无响应 \(Int(m)) 秒") }
            let t = now - tickBeat.value
            if t > tickLimit { restartSelf(reason: "采样线程无响应 \(Int(t)) 秒") }
            let fp = selfFootprint()
            if fp > memLimit { restartSelf(reason: "自身内存异常 \(bytes(fp))") }
        }
    }
}

// MARK: - 单实例

/// 找出其它正在运行的 MacMon 进程（不论从哪个路径启动）
func otherInstances() -> [pid_t] {
    let me = getpid()
    let myExe = Bundle.main.executablePath.map { ($0 as NSString).lastPathComponent } ?? "MacMon"
    return sampleProcs().filter { $0.pid != me && $0.name == myExe }.map { $0.pid }
}

func waitForOthersToExit(_ seconds: Double) -> [pid_t] {
    let deadline = monoNow() + seconds
    var others = otherInstances()
    while !others.isEmpty && monoNow() < deadline {
        usleep(200_000)
        others = otherInstances()
    }
    return others
}

func ensureSingleInstance() {
    var others = otherInstances()
    guard !others.isEmpty else { return }
    if launchedAsRestart {
        others = waitForOthersToExit(5)
    }
    if others.isEmpty { return }
    if underAgent {
        // 守护进程优先：接管手动打开的实例
        others.forEach { kill($0, SIGTERM) }
        others = waitForOthersToExit(3)
        others.forEach { kill($0, SIGKILL) }
        return
    }
    // 手动又双击了一次：让正在运行的那个弹出面板，自己退出
    DistributedNotificationCenter.default().postNotificationName(showNoteName, object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
}

// MARK: - 守护模式（LaunchAgent + KeepAlive）

func agentInstalled() -> Bool { FileManager.default.fileExists(atPath: agentPlistPath) }

func writeAgentPlist() throws {
    guard let exe = Bundle.main.executablePath else { throw NSError(domain: "macmon", code: 1) }
    let dict: [String: Any] = [
        "Label": agentLabel,
        "ProgramArguments": [exe],
        "RunAtLoad": true,
        "KeepAlive": ["SuccessfulExit": false],   // 非正常退出（崩溃/看门狗）自动拉起；菜单里“退出”不拉起
        "ThrottleInterval": 5,
        "ProcessType": "Interactive",             // 不被当成后台任务节流
        "LimitLoadToSessionType": "Aqua",
        "EnvironmentVariables": ["MACMON_AGENT": "1"],
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    try FileManager.default.createDirectory(atPath: (agentPlistPath as NSString).deletingLastPathComponent,
                                            withIntermediateDirectories: true)
    try data.write(to: URL(fileURLWithPath: agentPlistPath), options: .atomic)
}

// MARK: - 设置键 + 配置持久化

enum K {
    static let cpu = "cpuThreshold"
    static let cpuSustainSec = "cpuSustainSec"
    static let mem = "memThreshold"
    static let availMB = "availMinMB"
    static let swapGrowMB = "swapGrowMB"
    static let procCpu = "procCpuThreshold"
    static let appCpu = "appCpuThreshold"
    static let appSustainSec = "appSustainSec"
    static let appConn = "appConnThreshold"
    static let cooldownMin = "cooldownMin"
    static let soundOn = "soundOn"
    static let welcomed = "welcomed"
}

extension Config {
    static func load(_ d: UserDefaults) -> Config {
        var c = Config()
        c.interval = 3
        func num(_ k: String, _ def: Double) -> Double {
            guard d.object(forKey: k) != nil else { return def }
            let x = d.double(forKey: k)
            return x > 0 ? x : def
        }
        c.cpuThreshold = num(K.cpu, 85)
        c.cpuSustained = max(1, Int((num(K.cpuSustainSec, 30) / c.interval).rounded()))
        c.memThreshold = num(K.mem, 92)
        c.availMinMB = num(K.availMB, 200)
        c.swapGrowMB = num(K.swapGrowMB, 512)
        c.procCpuThreshold = num(K.procCpu, 60)
        c.appCpuThreshold = num(K.appCpu, 100)
        c.appSustainSec = num(K.appSustainSec, 60)
        c.appConnThreshold = num(K.appConn, 500)
        c.cooldown = num(K.cooldownMin, 10) * 60
        let soundOn = d.object(forKey: K.soundOn) == nil ? true : d.bool(forKey: K.soundOn)
        c.sound = soundOn ? "Glass" : "off"
        return c
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    // —— 只在 tickQ 上访问 ——
    let tickQ = DispatchQueue(label: "com.ck.macmon.tick", qos: .utility)
    let cpuS = CPUSampler()
    let netS = NetSampler()
    let ioS = DiskIOSampler()
    var engine: Engine!
    var history = History()
    var volumes: [Volume] = []
    var tickN = 0
    var prevSelfCPU = selfCPUSeconds()
    var prevSelfWall = monoNow()
    let autoKiller = AutoKiller()

    // —— 跨线程 ——
    let paused = Atomic(false)
    /// 用户在「即将结束」通知上点了「保留」的应用名（主线程写，tickQ 读）
    let keepRequests = Atomic<Set<String>>([])
    let autoKillGrace = 10.0
    /// 当前最前台应用（主线程通过系统通知更新，采样队列只读）
    let frontPid = Atomic<pid_t>(0)
    let frontPath = Atomic<String?>(nil)
    let watchdog = Watchdog()
    var logger: Logger!

    // —— 只在主线程访问 ——
    let model = Model()
    var latest = Snapshot()
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    var dashWindow: NSWindow?
    var settingsWindow: NSWindow?
    var lastTitle = ""
    var timerSource: DispatchSourceTimer?
    var pressureSource: DispatchSourceMemoryPressure?
    var napActivity: NSObjectProtocol?

    // ---------- 生命周期 ----------

    func applicationDidFinishLaunching(_ note: Notification) {
        watchdog.start()
        napActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep], reason: "MacMon 持续监控系统资源")

        logger = Logger(path: macmonDir + "/macmon.log", echo: false)
        logger.write("MacMon.app \(VERSION) 启动（\(underAgent ? "守护模式" : "普通模式")）")

        let logger = self.logger!
        engine = Engine(cfg: Config.load(.standard)) { [weak self] category, title, body in
            logger.write("⚠️ \(title) — \(body.replacingOccurrences(of: "\n", with: " / "))")
            DispatchQueue.main.async { self?.notify(category, title, body) }
        }

        wireModel()
        trackFrontmost()
        setupStatusItem()

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let hc = NSHostingController(rootView: PopoverView(m: model))
        hc.sizingOptions = .preferredContentSize
        popover.contentViewController = hc

        DistributedNotificationCenter.default().addObserver(
            forName: showNoteName, object: nil, queue: .main) { [weak self] _ in self?.showPopover() }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.ck.macmon.window"), object: nil, queue: .main) { [weak self] _ in self?.showDashboard() }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.ck.macmon.settings"), object: nil, queue: .main) { [weak self] _ in self?.showSettings() }
        // 调试：模拟在「即将结束」通知上点「保留」（只能取消、不能触发结束）
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.ck.macmon.keep"), object: nil, queue: .main) { [weak self] n in
            if let name = n.object as? String { self?.keepRequests.value.insert(name); self?.logger.write("🤖 收到「保留 \(name)」（调试）") }
        }
        // 调试：把弹窗/窗口自己渲染成 PNG（无需屏幕录制权限）→ ~/.macmon/shot-*.png
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.ck.macmon.snapshot"), object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated {
            self?.renderShots() }
        }

        UNUserNotificationCenter.current().delegate = self
        let keep = UNNotificationAction(identifier: keepActionID, title: "保留", options: [])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: preKillCategory, actions: [keep], intentIdentifiers: [], options: []),
        ])
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            // 没授权也要走一遍：自我恢复的消息还要推给 Webhook
            DispatchQueue.main.async { self?.postStartupNotes(granted: granted) }
        }

        startTick()
        startPressureSource()
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.disableCLIAgentIfNeeded() }

        if !underAgent && !launchedAsRestart {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in self?.showPopover() }
        }
    }

    private func wireModel() {
        model.agentOn = agentInstalled()
        model.terminate = { [weak self] name, pids in self?.performKill(name: name, pids: pids) }
        model.openWindow = { [weak self] in self?.showDashboard() }
        model.openSettings = { [weak self] in self?.showSettings() }
        model.togglePause = { [weak self] in
            guard let self = self else { return }
            self.paused.value.toggle()
            self.model.paused = self.paused.value
            self.logger.write(self.paused.value ? "⏸ 监控已暂停" : "▶️ 监控已恢复")
            self.lastTitle = ""
            self.updateStatusTitle(self.latest)
        }
        model.toggleAgent = { [weak self] in self?.toggleAgent() }
        model.testNotify = { [weak self] in
            self?.postUN("macmon.test", "✅ MacMon 通知通道正常", "自动结束应用前会这样提醒你（带「保留」按钮）。")
        }
        model.revealLog = {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: macmonDir + "/macmon.log")])
        }
        model.quit = { NSApp.terminate(nil) }
    }

    private func trackFrontmost() {
        let update: (NSRunningApplication?) -> Void = { [weak self] ra in
            self?.frontPid.value = ra?.processIdentifier ?? 0
            self?.frontPath.value = ra?.bundleURL?.path
        }
        update(NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            update(n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let b = statusItem.button else { return }
        let img = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "MacMon")
        img?.isTemplate = true
        b.image = img
        b.imagePosition = .imageLeading
        b.imageHugsTitle = true
        b.target = self
        b.action = #selector(togglePopover(_:))
        b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        b.attributedTitle = NSAttributedString(string: "")
    }

    private func postStartupNotes(granted: Bool) {
        if let reason = try? String(contentsOfFile: restartMarker, encoding: .utf8) {
            try? FileManager.default.removeItem(atPath: restartMarker)
            logger.write("🛡 上次自动重启原因：\(reason)")
            notify("selfrestart", "🛡 MacMon 已自我恢复", "检测到自身异常并自动重启：\(reason)")
        }
        if granted, !UserDefaults.standard.bool(forKey: K.welcomed) {
            UserDefaults.standard.set(true, forKey: K.welcomed)
            postUN("macmon.welcome", "👋 MacMon 已开始监控",
                   "CPU / 内存 / 网络 / 磁盘异常时会在这里提醒你。\n点菜单栏图标查看详情。")
        }
    }

    /// 旧版 CLI LaunchAgent 会重复报警，自动停用（后台线程执行，launchctl 带超时）
    private func disableCLIAgentIfNeeded() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let plist = home.appendingPathComponent("Library/LaunchAgents/com.ck.macmon.plist")
        guard FileManager.default.fileExists(atPath: plist.path) else { return }
        sh("/bin/launchctl", ["bootout", "gui/\(getuid())/com.ck.macmon"])
        try? FileManager.default.removeItem(at: plist)
        try? FileManager.default.removeItem(at: home.appendingPathComponent(".macmon/bin/macmon"))
        try? FileManager.default.removeItem(at: home.appendingPathComponent(".macmon/macmon.pid"))
        logger.write("已停用旧版命令行 LaunchAgent")
    }

    // ---------- 采样循环（全部在 tickQ） ----------

    private func startTick() {
        let t = DispatchSource.makeTimerSource(queue: tickQ)
        t.schedule(deadline: .now() + 0.5, repeating: .seconds(3), leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timerSource = t
    }

    private func startPressureSource() {
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: tickQ)
        src.setEventHandler { [weak self, weak src] in
            guard let self = self, let src = src, !self.paused.value else { return }
            self.engine.kernelPressure(critical: src.data.contains(.critical))
        }
        src.resume()
        pressureSource = src
    }

    private func tick() {
        let t0 = monoNow()
        engine.cfg = Config.load(.standard)
        let wall = Date()
        let cpu = cpuS.sample()
        let mem = memSample()
        let procs = sampleProcs()
        let conns = connCounts(procs.map { $0.pid })   // ~0.6ms：只读内核套接字表
        let top = engine.procCPUs(procs, wall: wall, conns: conns)
        if !paused.value {
            engine.evaluate(cpu: cpu, mem: mem, procList: top, wall: wall)
        }
        let net = netS.sample() ?? NetSnap()
        let io = ioS.sample()
        if tickN % 5 == 0 { volumes = listVolumes() }   // 磁盘容量 15 秒刷新一次就够
        tickN += 1

        var snap = Snapshot()
        snap.cpu = cpu
        snap.mem = mem
        snap.load = loadAvg()
        snap.net = net
        snap.io = io
        snap.volumes = volumes
        snap.topCpu = top
        snap.apps = engine.lastApps.isEmpty ? groupByApp(top) : engine.lastApps
        snap.thermal = ProcessInfo.processInfo.thermalState

        // —— 自动处理（默认关闭；只处理名单内应用）——
        if !paused.value,
           let (victim, reason) = autoKiller.decide(cfg: AutoKillConfig.load(), apps: snap.apps, cpu: cpu, mem: mem,
                                                    frontPid: frontPid.value, frontPath: frontPath.value) {
            let grace = autoKillGrace
            logger.write("🤖 即将自动结束 \(victim.name)（\(victim.pids.count) 个进程）— \(reason)；\(Int(grace)) 秒后执行")
            keepRequests.value.remove(victim.name)
            DispatchQueue.main.async { [weak self] in self?.notifyPreKill(victim.name, reason: reason, grace: grace) }
            tickQ.asyncAfter(deadline: .now() + grace) { [weak self] in self?.executeAutoKill(victim) }
        }
        if cpu != nil {
            history.add(cpu: snap.busy, mem: snap.memFrac * 100, net: net, io: io)
        }
        snap.history = history

        let t1 = monoNow()
        let cpuSec = selfCPUSeconds()
        if t1 > prevSelfWall { snap.me.cpuPct = (cpuSec - prevSelfCPU) / (t1 - prevSelfWall) * 100 }
        prevSelfCPU = cpuSec
        prevSelfWall = t1
        snap.me.footprint = selfFootprint()
        snap.me.tickMs = (t1 - t0) * 1000

        watchdog.tickBeat.value = t1
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.latest = snap
            self.updateStatusTitle(snap)
            if self.uiVisible { self.model.snap = snap }   // 界面不可见时不触发任何 SwiftUI 计算
        }
    }

    private var uiVisible: Bool {
        if popover.isShown { return true }
        if let w = dashWindow, w.isVisible, w.occlusionState.contains(.visible) { return true }
        return false
    }

    private func updateStatusTitle(_ s: Snapshot) {
        guard s.cpu != nil, s.mem != nil else { return }
        let busy = Int(s.busy.rounded())
        let mp = Int((s.memFrac * 100).rounded())
        let text = paused.value ? " 已暂停" : " \(busy)%  \(mp)%"
        let (h, _) = s.health
        let key = text + "\(h)"
        guard key != lastTitle else { return }   // 没变化就不重绘
        lastTitle = key
        var attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium),
        ]
        if !paused.value && h != .good { attrs[.foregroundColor] = h == .bad ? NSColor.systemRed : NSColor.systemOrange }
        statusItem.button?.attributedTitle = NSAttributedString(string: text, attributes: attrs)
    }

    // ---------- 弹窗 / 窗口 ----------

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown { popover.performClose(sender) } else { showPopover() }
    }

    private func showPopover() {
        guard let b = statusItem.button, !popover.isShown else { return }
        model.snap = latest
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidShow(_ notification: Notification) { model.snap = latest }

    @MainActor private func renderShots() {
        func save(_ v: NSView?, _ name: String) {
            guard let v = v, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: macmonDir + "/shot-\(name).png"))
        }
        if popover.isShown { save(popover.contentViewController?.view, "popover") }
        // 连接最多的应用的明细（先触发 DNS 反查，2 秒后再渲染）
        if let top = latest.apps.max(by: { $0.conns < $1.conns }), top.conns > 0 {
            let detail = connDetails(top.pids)
            detail.forEach { _ = model.dns.host($0.remote) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self = self else { return }
                MainActor.assumeIsolated {
                    let r = ImageRenderer(content: ConnectionsView(m: self.model, dns: self.model.dns, name: top.name,
                                                                   path: top.appPath, pids: top.pids, initial: detail)
                        .background(Color(white: 0.96)).environment(\.colorScheme, .light))
                    r.scale = 2
                    if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: macmonDir + "/shot-conns.png"))
                    }
                }
            }
        }
        for (dark, tag) in [(false, "light"), (true, "dark")] {
            let r = ImageRenderer(content: PopoverView(m: model)
                .background(dark ? Color(white: 0.16) : Color(white: 0.96))
                .environment(\.colorScheme, dark ? .dark : .light))
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: macmonDir + "/shot-render-\(tag).png"))
            }
        }
        if let w = dashWindow, w.isVisible { save(w.contentView, "window") }
        if let w = settingsWindow, w.isVisible, let tabs = w.contentViewController as? NSTabViewController {
            let keep = tabs.selectedTabViewItemIndex
            for i in 0..<tabs.tabViewItems.count {
                tabs.selectedTabViewItemIndex = i
                w.contentView?.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                save(w.contentView, "settings-\(i)")
            }
            tabs.selectedTabViewItemIndex = keep
        }
        // 行内“确认结束”状态预览
        if let a = latest.apps.first {
            let r = RowItem(id: a.name, name: a.name, path: a.appPath, count: a.pids.count, pid: a.mainPid, pct: a.pct,
                            mem: a.mem, disk: a.diskRate, conns: a.conns, listens: a.listens, pids: a.pids)
            let v = VStack(spacing: 0) {
                AppRow(m: model, r: r, sort: .cpu, previewConfirming: true)
                ToastView(t: Model.Toast(text: "已结束 \(a.name)", ok: true)).padding(.top, 8)
            }.padding(12).frame(width: 400).background(Color(white: 0.96)).environment(\.colorScheme, .light)
            let rr = ImageRenderer(content: v)
            rr.scale = 2
            if let img = rr.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: macmonDir + "/shot-confirm.png"))
            }
        }
    }

    private func showDashboard() {
        popover.performClose(nil)
        if dashWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 800),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.title = "MacMon"
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: DashboardView(m: model))
            w.delegate = self
            w.center()
            w.setFrameAutosaveName("MacMonDashboard")
            dashWindow = w
        }
        model.snap = latest
        NSApp.activate(ignoringOtherApps: true)
        dashWindow?.makeKeyAndOrderFront(nil)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        if uiVisible { model.snap = latest }
    }

    private func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            // 系统偏好设置风格：顶部工具栏图标标签页，每页固定尺寸、内容自己滚动
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            tabs.canPropagateSelectedChildViewControllerTitle = true
            let size = NSSize(width: 540, height: 500)
            func page<V: View>(_ title: String, _ symbol: String, _ v: V) {
                let hc = NSHostingController(rootView: v.frame(minWidth: size.width, minHeight: 360))
                hc.preferredContentSize = size
                hc.title = title
                let item = NSTabViewItem(viewController: hc)
                item.label = title
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
                tabs.addTabViewItem(item)
            }
            page("阈值", "gauge.with.dots.needle.67percent", AlertSettingsView())
            page("通知", "bell.badge", NotifySettingsView(m: model))
            page("自动处理", "bolt.shield", AutoKillSettingsView(m: model))
            page("通用", "gearshape", GeneralSettingsView(m: model))

            let w = NSWindow(contentViewController: tabs)
            w.styleMask = [.titled, .closable, .resizable]
            w.toolbarStyle = .preference
            w.isReleasedWhenClosed = false
            w.setContentSize(size)
            w.contentMinSize = NSSize(width: size.width, height: 360)
            w.center()
            w.setFrameAutosaveName("MacMonSettings")
            settingsWindow = w
        }
        model.snap = latest   // 让「添加正在运行的应用」列表是最新的
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        // 打开时不要自动选中第一个输入框
        DispatchQueue.main.async { [weak self] in self?.settingsWindow?.makeFirstResponder(nil) }
    }

    // ---------- 通知 ----------

    /// 倒计时结束后执行（在 tickQ 上）：用户点了「保留」/ 切到了前台 / 已自行退出 → 不结束
    private func executeAutoKill(_ victim: AppUsage) {
        let name = victim.name
        if keepRequests.value.contains(name) {
            keepRequests.value.remove(name)
            autoKiller.exempt(name, for: 1800)
            logger.write("🤖 已取消自动结束 \(name)：你选择了保留（30 分钟内不再处理它）")
            return
        }
        if victim.pids.contains(frontPid.value) || (frontPath.value != nil && victim.appPath == frontPath.value) {
            autoKiller.exempt(name, for: 600)
            logger.write("🤖 已取消自动结束 \(name)：倒计时期间你切到了它（10 分钟内不再处理它）")
            return
        }
        var v = victim
        v.pids = victim.pids.filter { kill($0, 0) == 0 }
        guard !v.pids.isEmpty else {
            autoKiller.finished(name)
            logger.write("🤖 \(name) 在倒计时期间已自行退出")
            return
        }
        terminateApp(v) { [weak self] forced in
            self?.logger.write("🤖 \(name) " + (forced > 0 ? "正常退出无响应，已强制结束" : "已正常退出"))
        }
    }

    /// 自动结束前的唯一一条通知（带「保留」按钮），同时推给 Webhook
    private func notifyPreKill(_ name: String, reason: String, grace: Double) {
        let title = "⏳ 即将结束 \(name)"
        let body = "\(reason)。\n\(Int(grace)) 秒后自动结束；点「保留」可取消。"
        let d = UserDefaults.standard
        if d.object(forKey: Hooks.localOn) == nil || d.bool(forKey: Hooks.localOn) {
            let c = UNMutableNotificationContent()
            c.title = title
            c.body = body
            c.categoryIdentifier = preKillCategory
            c.userInfo = ["app": name]
            c.interruptionLevel = .timeSensitive
            if d.object(forKey: K.soundOn) == nil || d.bool(forKey: K.soundOn) { c.sound = .default }
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "macmon.prekill.\(name)", content: c, trigger: nil))
        }
        let logger = self.logger
        WebhookSender.shared.broadcast(category: "prekill", title: title,
                                       body: "\(reason)。\(Int(grace)) 秒后自动结束（可在电脑上的通知里点「保留」取消）。") { logger?.write($0) }
    }

    /// 资源报警出口：默认只写日志；在 设置 → 通知 打开「资源报警」后才发本机通知 / Webhook
    private func notify(_ category: String, _ title: String, _ body: String) {
        let d = UserDefaults.standard
        guard d.bool(forKey: Hooks.alertsOn) else { return }
        if d.object(forKey: Hooks.localOn) == nil || d.bool(forKey: Hooks.localOn) {
            postUN("macmon.alert.\(category)", title, body)
        }
        let logger = self.logger
        WebhookSender.shared.broadcast(category: category, title: title, body: body) { logger?.write($0) }
    }

    private func postUN(_ id: String, _ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let soundOn = UserDefaults.standard.object(forKey: K.soundOn) == nil
            || UserDefaults.standard.bool(forKey: K.soundOn)
        if soundOn { content.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == keepActionID,
           let name = response.notification.request.content.userInfo["app"] as? String {
            keepRequests.value.insert(name)   // 倒计时结束时会看到并取消
            logger.write("🤖 收到「保留 \(name)」")
        } else {
            DispatchQueue.main.async { [weak self] in self?.showDashboard() }   // 点通知 → 打开监控窗口
        }
        completionHandler()
    }

    // ---------- 结束进程 ----------

    /// 手动结束（确认已在行内完成）：不关弹窗、不弹系统对话框，结果在界面底部提示
    private func performKill(name: String, pids: [pid_t]) {
        guard !model.killing.contains(name) else { return }
        model.killing.insert(name)
        logger.write("手动结束 \(name) \(pids)")
        terminatePids(pids) { [weak self] forced, denied in
            guard let self = self else { return }
            self.model.killing.remove(name)
            let text: String
            let ok: Bool
            if denied {
                text = "无法结束 \(name)：系统或其他用户的进程，没有权限"
                ok = false
            } else if forced > 0 {
                text = "已强制结束 \(name)（\(forced) 个进程无响应）"
                ok = true
            } else {
                text = "已结束 \(name)"
                ok = true
            }
            self.logger.write(text)
            self.model.showToast(text, ok: ok)
        }
    }

    // ---------- 守护模式 ----------

    private func toggleAgent() {
        let uid = getuid()
        if agentInstalled() {
            try? FileManager.default.removeItem(atPath: agentPlistPath)
            model.agentOn = false
            logger.write("守护模式已关闭")
            logger.flush()
            let bundlePath = Bundle.main.bundlePath
            let wasAgent = underAgent
            DispatchQueue.global(qos: .userInitiated).async {
                // 自己就是守护进程：先拉起一个普通实例接班，再让 launchd 卸载自己
                if wasAgent { sh("/usr/bin/open", ["-n", bundlePath, "--args", "--restarted"]) }
                sh("/bin/launchctl", ["bootout", "gui/\(uid)/\(agentLabel)"], timeout: 10)
            }
            return
        }
        do {
            try writeAgentPlist()
        } catch {
            let a = NSAlert()
            a.messageText = "开启守护模式失败"
            a.informativeText = "\(error)"
            a.runModal()
            return
        }
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
        model.agentOn = true
        logger.write("守护模式已开启，交给 launchd 接管")
        logger.flush()
        let path = agentPlistPath
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            sh("/bin/launchctl", ["bootout", "gui/\(uid)/\(agentLabel)"], timeout: 10)
            let rc = sh("/bin/launchctl", ["bootstrap", "gui/\(uid)", path], timeout: 10)
            DispatchQueue.main.async {
                if rc == 0 {
                    // 守护实例启动后会接管（结束本实例）；保险起见本实例也主动退出
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { exit(0) }
                } else {
                    try? FileManager.default.removeItem(atPath: path)
                    self?.model.agentOn = false
                    self?.postUN("macmon.agent", "⚠️ 开启守护模式失败", "launchctl 返回 \(rc)")
                }
            }
        }
    }
}

// MARK: - main

signal(SIGPIPE, SIG_IGN)
ensureSingleInstance()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)

// 隐藏的自检开关：MACMON_SELFTEST_HANG=秒 → 启动后故意让主线程卡死，用来验证看门狗
if let s = ProcessInfo.processInfo.environment["MACMON_SELFTEST_HANG"], let sec = Double(s) {
    DispatchQueue.main.asyncAfter(deadline: .now() + sec) { while true { usleep(1_000_000) } }
}

app.run()
