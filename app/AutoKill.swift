// MacMon — 自动处理（自动结束失控应用）
//
// 安全原则（缺一不可才会动手）：
//   1. 默认关闭，用户在设置里手动开启
//   2. 只处理用户加入「自动处理名单」的应用；名单外的永远只报警
//   3. 系统必须真的有麻烦：
//        CPU 路线：整机 CPU ≥ 80% 且 该应用合计 CPU ≥ 阈值（默认 200% = 2 核），持续 ≥ 阈值时长（默认 3 分钟）
//        内存路线：内存压力「严重」（或「警告」且 Swap ≥ 75%）且 该应用合计内存 ≥ 阈值（默认 3GB），持续 ≥ 30 秒
//   4. 永不处理：系统进程、MacMon 自己、当前正在使用的（最前台）应用
//   5. 先请求正常退出（应用可以保存），5 秒后仍在才强制结束
//   6. 限速：10 分钟内最多自动结束 1 个
//   7. 事后发通知 + 写日志
import AppKit
import Darwin

enum AK {
    static let on = "autoKillOn"
    static let list = "autoKillList"          // 换行分隔的应用名
    static let cpu = "autoKillCpu"            // %
    static let cpuSec = "autoKillCpuSec"      // 秒
    static let memGB = "autoKillMemGB"        // GB
    static let sysBusy = "autoKillSysBusy"    // 隐藏：整机 CPU 门槛（测试用）
    static let gapMin = "autoKillGapMin"      // 隐藏：两次自动结束最小间隔（分钟）

    /// 名单里加了也绝不处理的
    static let neverKill: Set<String> = [
        "MacMon", "Finder", "Dock", "WindowServer", "loginwindow", "SystemUIServer", "kernel_task",
        "launchd", "ControlCenter", "NotificationCenter", "Spotlight", "coreaudiod", "System Settings", "系统设置",
    ]

    static func names(_ d: UserDefaults = .standard) -> [String] {
        (d.string(forKey: list) ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func setNames(_ n: [String], _ d: UserDefaults = .standard) {
        d.set(n.joined(separator: "\n"), forKey: list)
    }
}

struct AutoKillConfig {
    var enabled = false
    var names: Set<String> = []
    var cpuPct: Double = 200
    var cpuSec: Double = 180
    var memBytes: UInt64 = 3 << 30
    var sysBusy: Double = 80
    var memSec: Double = 30
    var gap: Double = 600

    static func load(_ d: UserDefaults = .standard) -> AutoKillConfig {
        func num(_ k: String, _ def: Double) -> Double {
            guard d.object(forKey: k) != nil else { return def }
            let x = d.double(forKey: k)
            return x >= 0 ? x : def
        }
        var c = AutoKillConfig()
        c.enabled = d.bool(forKey: AK.on)
        c.names = Set(AK.names(d))
        c.cpuPct = max(50, num(AK.cpu, 200))
        c.cpuSec = max(10, num(AK.cpuSec, 180))
        c.memBytes = UInt64(max(0.5, num(AK.memGB, 3)) * 1_073_741_824)
        c.sysBusy = num(AK.sysBusy, 80)
        c.gap = max(60, num(AK.gapMin, 10) * 60)
        return c
    }
}

/// 只在采样队列（tickQ）上使用
final class AutoKiller {
    private var cpuSince: [String: Double] = [:]
    private var memSince: [String: Double] = [:]
    private var misses: [String: Int] = [:]
    private var lastKill = -1e9
    private var dying: [String: Double] = [:]   // 刚下令结束的应用 → 时间

    /// 返回本轮应自动结束的应用及原因（最多 1 个）；不满足条件返回 nil
    func decide(cfg: AutoKillConfig, apps: [AppUsage], cpu: CPUSnap?, mem: MemSnap?,
                frontPid: pid_t, frontPath: String?) -> (AppUsage, String)? {
        guard cfg.enabled, !cfg.names.isEmpty else { cpuSince.removeAll(); memSince.removeAll(); return nil }
        let now = monoNow()
        let busy = cpu.map { 100 - $0.idle } ?? 0
        let memTrouble: Bool = {
            guard let m = mem else { return false }
            if m.pressure == .critical { return true }
            if m.pressure == .warning, m.swapTotal > 0, Double(m.swapUsed) / Double(m.swapTotal) >= 0.75 { return true }
            return false
        }()
        let me = getpid()
        var pick: (AppUsage, String)? = nil

        // 已退出 / 移出名单的应用：清掉计时，防止旧计时让新启动的同名应用被“秒杀”
        let present = Set(apps.map { $0.name }).intersection(cfg.names)
        cpuSince = cpuSince.filter { present.contains($0.key) }
        memSince = memSince.filter { present.contains($0.key) }
        misses = misses.filter { present.contains($0.key) }

        dying = dying.filter { now - $0.value < 15 }
        for a in apps where cfg.names.contains(a.name) && !AK.neverKill.contains(a.name) {
            // 正在被结束的（等待强制的 5 秒内）不重新计时
            if dying[a.name] != nil { cpuSince[a.name] = nil; memSince[a.name] = nil; continue }
            // —— CPU 路线（允许偶尔 1 次采样掉下去，避免抖动清零）——
            let cpuHot = busy >= cfg.sysBusy && a.pct >= cfg.cpuPct
            if cpuHot {
                misses[a.name] = 0
                if cpuSince[a.name] == nil { cpuSince[a.name] = now }
            } else {
                let m = (misses[a.name] ?? 0) + 1
                misses[a.name] = m
                if m >= 2 { cpuSince[a.name] = nil }
            }
            // —— 内存路线 ——
            if memTrouble && a.mem >= cfg.memBytes {
                if memSince[a.name] == nil { memSince[a.name] = now }
            } else {
                memSince[a.name] = nil
            }

            guard pick == nil else { continue }
            var reason: String? = nil
            // 动手那一刻必须“此刻”仍然满足条件（容错只用于计时不被抖动清零，不用于触发）
            if cpuHot, let s = cpuSince[a.name], now - s >= cfg.cpuSec {
                reason = String(format: "合计 CPU %.0f%%（≈%.1f 个核）已持续 %d 秒，整机 CPU %.0f%%",
                                a.pct, a.pct / 100, Int(now - s), busy)
            } else if let s = memSince[a.name], now - s >= cfg.memSec, let m = mem {
                reason = "占用内存 \(bytes(a.mem))，系统内存压力「\(m.pressure == .critical ? "严重" : "警告")」、Swap \(bytes(m.swapUsed))"
            }
            guard let r = reason else { continue }
            // —— 永不处理：前台应用 / 自己 ——
            if a.pids.contains(frontPid) || (frontPath != nil && a.appPath == frontPath) { continue }
            if a.pids.contains(me) { continue }
            pick = (a, r)
        }

        guard let p = pick else { return nil }
        guard now - lastKill >= cfg.gap else { return nil }   // 限速
        lastKill = now
        cpuSince[p.0.name] = nil
        memSince[p.0.name] = nil
        dying[p.0.name] = now
        return p
    }
}

/// 结束一组进程：GUI 应用先走正常“退出”（等同 ⌘Q，可保存），其余发 SIGTERM；grace 秒后仍在就 SIGKILL。
/// completion 在主线程回调：forced = 被强制结束的进程数，denied = 全部无权限。
func terminatePids(_ pids: [pid_t], grace: Double = 5, completion: @escaping (_ forced: Int, _ denied: Bool) -> Void) {
    let me = getpid()
    let targets = pids.filter { $0 > 1 && $0 != me }
    DispatchQueue.main.async {
        guard !targets.isEmpty else { completion(0, false); return }
        var asked = false
        for p in targets {
            if let ra = NSRunningApplication(processIdentifier: p), ra.activationPolicy != .prohibited {
                asked = ra.terminate() || asked
            }
        }
        if !asked {
            var denied = 0
            for p in targets where kill(p, SIGTERM) != 0 && errno == EPERM { denied += 1 }
            if denied == targets.count { completion(0, true); return }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
            let alive = targets.filter { kill($0, 0) == 0 }
            alive.forEach { kill($0, SIGKILL) }
            DispatchQueue.main.async { completion(alive.count, false) }
        }
    }
}

func terminateApp(_ a: AppUsage, completion: @escaping (_ forced: Int) -> Void) {
    terminatePids(a.pids) { forced, _ in completion(forced) }
}
