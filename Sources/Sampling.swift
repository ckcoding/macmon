// macmon — 采样层（App 与 CLI 共用）
//
// 低开销 + 防卡死原则（本文件所有代码都遵守）：
//   1. 只用内核接口（Mach / libproc / sysctl / IOKit 注册表），绝不 shell 出去调 ps/top/nettop/iostat。
//   2. 每个进程每轮只做 1 次系统调用（proc_pid_rusage 一次拿到 CPU、内存、磁盘 IO）。
//   3. 磁盘容量用 getfsstat(MNT_NOWAIT)：只读内核缓存，网络盘（SMB/NFS）掉线也不会卡住。
//   4. 网络用一次 sysctl(NET_RT_IFLIST2) 取所有网卡 64 位计数器。
//   5. 缓冲区复用，进程名缓存，避免每轮分配。
//   6. 外部命令（只有 launchctl/osascript）都有超时；日志异步写。
import Foundation
import Darwin
import IOKit

let VERSION = "2.0.0"

// MARK: - 配置

struct Config {
    var interval: Double = 5            // 采样间隔（秒）
    var cpuThreshold: Double = 85       // 系统 CPU 忙碌阈值 %
    var cpuSustained: Int = 6           // 连续超标次数（6 * 5s = 30s）
    var memThreshold: Double = 92       // 内存已用阈值 %
    var availMinMB: Double = 200        // 可用内存下限 MB
    var swapGrowMB: Double = 512        // 单周期 swap 增长报警 MB
    var procCpuThreshold: Double = 60   // 单进程 CPU 阈值 %
    var procSustainSec: Double = 180    // 单进程持续时长（秒）
    var appCpuThreshold: Double = 100   // 单应用（含全部 Helper）合计 CPU 阈值 %（100% = 1 个核）
    var appSustainSec: Double = 60      // 应用持续高占用多久报警
    var appMemFraction: Double = 0.30   // 单应用合计内存占物理内存比例阈值
    var appConnThreshold: Double = 500  // 单应用网络连接数阈值（连接泄漏 / 狂发请求）
    var diskMinGB: Double = 10          // 磁盘剩余下限 GB
    var cooldown: Double = 600          // 同类报警冷却（秒）
    var topN: Int = 5
    var logPath: String? = nil
    var logSamples: Bool = false
    var notify: Bool = true
    var sound: String = "Glass"
}

let iso: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

// MARK: - 小工具

func bytes(_ b: UInt64) -> String {
    let mb = Double(b) / 1048576.0
    if mb >= 1024 * 1024 { return String(format: "%.2f TB", mb / 1048576) }
    if mb >= 1024 { return String(format: mb >= 10240 ? "%.0f GB" : "%.1f GB", mb / 1024) }
    return String(format: "%.0f MB", mb)
}

/// 速率：B/s → “1.2 MB/s”
func rate(_ bps: Double) -> String {
    if bps < 1024 { return String(format: "%.0f B/s", bps) }
    if bps < 1048576 { return String(format: "%.0f KB/s", bps / 1024) }
    if bps < 1073741824 { return String(format: "%.1f MB/s", bps / 1048576) }
    return String(format: "%.2f GB/s", bps / 1073741824)
}

func pct(_ v: Double) -> String { String(format: "%.1f%%", v) }

func expandPath(_ p: String) -> String {
    let home = NSHomeDirectory()
    if p == "~" { return home }
    if p.hasPrefix("~/") { return home + p.dropFirst() }
    return p
}

func esc(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
}

/// 运行外部命令，带超时：超时先 SIGTERM，0.5 秒后 SIGKILL。永远不会无限等待。
/// 返回退出码；-1 启动失败；-2 超时被杀。
@discardableResult
func sh(_ path: String, _ args: [String], timeout: Double = 5) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    let done = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in done.signal() }
    do { try p.run() } catch { return -1 }
    if done.wait(timeout: .now() + timeout) == .timedOut {
        p.terminate()
        if done.wait(timeout: .now() + 0.5) == .timedOut {
            kill(p.processIdentifier, SIGKILL)
            _ = done.wait(timeout: .now() + 0.5)
        }
        return -2
    }
    return p.terminationStatus
}

func loadAvg() -> (Double, Double, Double)? {
    var la = [Double](repeating: 0, count: 3)
    guard getloadavg(&la, 3) == 3 else { return nil }
    return (la[0], la[1], la[2])
}

/// 根分区剩余（本地盘，statfs 不会卡）
func diskFree() -> (freeGB: Double, totalGB: Double)? {
    var fs = statfs()
    guard statfs("/", &fs) == 0 else { return nil }
    let unit = Double(fs.f_bsize)
    return (Double(fs.f_bavail) * unit / 1073741824.0, Double(fs.f_blocks) * unit / 1073741824.0)
}

/// 本进程实际占用内存（与「活动监视器」的“内存”列口径一致）
func selfFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? info.phys_footprint : 0
}

/// 本进程累计 CPU 时间（秒）
func selfCPUSeconds() -> Double {
    var ru = rusage()
    getrusage(RUSAGE_SELF, &ru)
    return Double(ru.ru_utime.tv_sec + ru.ru_stime.tv_sec)
        + Double(ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) / 1_000_000
}

/// 单调时钟（秒）。系统睡眠时不走，避免合盖再打开被误判为“卡死”。
func monoNow() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

/// Mach 时间单位 → 纳秒。Apple Silicon 上是 125/3（不换算 CPU% 会小 41.67 倍）。
let machToNs: Double = {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return tb.denom == 0 ? 1 : Double(tb.numer) / Double(tb.denom)
}()

func sysctlInt(_ name: String) -> Int? {
    var v: Int64 = 0
    var size = MemoryLayout<Int64>.size
    guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
    if size == 4 { return Int(Int32(truncatingIfNeeded: v)) }
    return Int(v)
}

// MARK: - 日志（异步，绝不阻塞调用方）

final class Logger {
    let path: String?
    let echo: Bool
    private var handle: FileHandle?
    private let q = DispatchQueue(label: "com.ck.macmon.log", qos: .background)
    private var writes = 0

    init(path: String?, echo: Bool = true) {
        self.path = path
        self.echo = echo
        guard let p = path else { return }
        q.async { self.open(p) }
    }

    private func open(_ p: String) {
        let url = URL(fileURLWithPath: p)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: p) {
            FileManager.default.createFile(atPath: p, contents: nil)
        }
        handle = FileHandle(forWritingAtPath: p)
        handle?.seekToEndOfFile()
    }

    func write(_ s: String) {
        if echo { out(s) }
        guard let p = path else { return }
        let line = "[\(iso.string(from: Date()))] " + s + "\n"
        q.async {
            self.writes += 1
            if self.writes % 50 == 0,
               let attrs = try? FileManager.default.attributesOfItem(atPath: p),
               let sz = attrs[.size] as? UInt64, sz > 10 * 1024 * 1024 {
                self.handle?.closeFile()
                try? FileManager.default.removeItem(atPath: p + ".1")
                try? FileManager.default.moveItem(atPath: p, toPath: p + ".1")
                self.open(p)
            }
            self.handle?.write(Data(line.utf8))
        }
    }

    func flush(timeout: Double = 1) {
        let s = DispatchSemaphore(value: 0)
        q.async { s.signal() }
        _ = s.wait(timeout: .now() + timeout)
    }
}

func out(_ s: String) {
    FileHandle.standardOutput.write(Data((s + "\n").utf8))
}

// MARK: - CPU（Mach ticks 差分，含每核）

struct CPUSnap {
    let user: Double   // 含 nice
    let sys: Double
    let idle: Double
    var perCore: [Double] = []   // 每核忙碌 %
}

final class CPUSampler {
    private var prev: [(u: Int, s: Int, i: Int)] = []

    func sample() -> CPUSnap? {
        var numCPUs: natural_t = 0
        var info: processor_info_array_t? = nil
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                     &numCPUs, &info, &infoCount)
        guard kr == KERN_SUCCESS, let p = info else { return nil }
        defer {
            let sz = MemoryLayout<integer_t>.stride * Int(infoCount)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: p)), vm_size_t(sz))
        }
        var cur: [(u: Int, s: Int, i: Int)] = []
        cur.reserveCapacity(Int(numCPUs))
        for c in 0..<Int(numCPUs) {
            let b = c * Int(CPU_STATE_MAX)
            cur.append((Int(UInt32(bitPattern: p[b + Int(CPU_STATE_USER)])) + Int(UInt32(bitPattern: p[b + Int(CPU_STATE_NICE)])),
                        Int(UInt32(bitPattern: p[b + Int(CPU_STATE_SYSTEM)])),
                        Int(UInt32(bitPattern: p[b + Int(CPU_STATE_IDLE)]))))
        }
        defer { prev = cur }
        guard prev.count == cur.count else { return nil }
        var du = 0, ds = 0, di = 0
        var per: [Double] = []
        per.reserveCapacity(cur.count)
        for (a, b) in zip(cur, prev) {
            // tick 计数器是 32 位，回绕时按 0 处理
            let u = max(0, a.u - b.u), s = max(0, a.s - b.s), i = max(0, a.i - b.i)
            du += u; ds += s; di += i
            let t = u + s + i
            per.append(t > 0 ? Double(u + s) / Double(t) * 100 : 0)
        }
        let dt = du + ds + di
        guard dt > 0 else { return nil }
        return CPUSnap(user: Double(du) / Double(dt) * 100.0,
                       sys: Double(ds) / Double(dt) * 100.0,
                       idle: Double(di) / Double(dt) * 100.0,
                       perCore: per)
    }
}

// MARK: - 内存 / Swap（口径与「活动监视器」一致）

struct XswUsage {
    var total: UInt64 = 0
    var avail: UInt64 = 0
    var used: UInt64 = 0
    var pagesize: UInt32 = 0
    var encrypted: Int32 = 0
}

enum Pressure: Int { case normal = 1, warning = 2, critical = 4 }

struct MemSnap {
    let total: UInt64
    let used: UInt64        // App 内存 + 联动 + 被压缩
    let avail: UInt64
    let app: UInt64
    let wired: UInt64
    let compressed: UInt64
    let cached: UInt64      // 缓存文件（可随时回收）
    let swapTotal: UInt64
    let swapUsed: UInt64
    let swapIns: UInt64     // 累计
    let swapOuts: UInt64    // 累计
    let pressure: Pressure
}

let cachedPageSize: UInt64 = {
    var ps: vm_size_t = 0
    if host_page_size(mach_host_self(), &ps) == KERN_SUCCESS, ps > 0 { return UInt64(ps) }
    return 4096
}()

func hostPageSize() -> UInt64 { cachedPageSize }

func memSample() -> MemSnap? {
    let ps = hostPageSize()
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
    var kr: kern_return_t = KERN_FAILURE
    withUnsafeMutablePointer(to: &stats) { p in
        p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { q in
            kr = host_statistics64(mach_host_self(), HOST_VM_INFO64, host_info64_t(q), &count)
        }
    }
    guard kr == KERN_SUCCESS else { return nil }

    let total = ProcessInfo.processInfo.physicalMemory
    let purge = UInt64(stats.purgeable_count)
    let intPages = UInt64(stats.internal_page_count)
    let app = (intPages > purge ? intPages - purge : 0) * ps
    let wired = UInt64(stats.wire_count) * ps
    let compressed = UInt64(stats.compressor_page_count) * ps
    let cached = (UInt64(stats.external_page_count) + purge) * ps
    let used = min(total, app + wired + compressed)

    var swapTotal: UInt64 = 0, swapUsed: UInt64 = 0
    var xs = XswUsage()
    var size = MemoryLayout<XswUsage>.stride
    if sysctlbyname("vm.swapusage", &xs, &size, nil, 0) == 0,
       xs.total > 0, xs.total < (1 << 42) {
        swapTotal = xs.total
        swapUsed = xs.used
    }
    let pressure = Pressure(rawValue: sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1) ?? .normal
    return MemSnap(total: total, used: used, avail: total - used, app: app, wired: wired,
                   compressed: compressed, cached: cached,
                   swapTotal: swapTotal, swapUsed: swapUsed,
                   swapIns: UInt64(stats.swapins), swapOuts: UInt64(stats.swapouts),
                   pressure: pressure)
}

// MARK: - 进程（每进程 1 次 proc_pid_rusage）

struct ProcSample {
    let pid: pid_t
    let name: String
    let app: String        // 所属应用（Helper 归到主应用名下）
    let appPath: String?   // 所属 .app 路径（取图标用）
    let cpuNs: UInt64      // 累计 CPU 时间（纳秒）
    let mem: UInt64        // 实际内存 phys_footprint（同活动监视器“内存”列）
    let diskR: UInt64      // 累计磁盘读字节
    let diskW: UInt64      // 累计磁盘写字节
}

/// /Applications/GitHub Desktop.app/Contents/Frameworks/GitHub Desktop Helper (Renderer).app/... →（“GitHub Desktop”, “/Applications/GitHub Desktop.app”）
func appIdentity(fromPath path: String, fallback: String) -> (String, String?) {
    guard let r = path.range(of: ".app/") else { return (fallback, nil) }
    let head = path[..<r.lowerBound]
    let appPath = String(path[..<path.index(r.lowerBound, offsetBy: 4)])
    if let slash = head.lastIndex(of: "/") {
        let n = head[head.index(after: slash)...]
        if !n.isEmpty { return (String(n), appPath) }
    }
    return (fallback, nil)
}

private struct Ident { let name: String; let app: String; let appPath: String? }
private var nameCache: [pid_t: Ident] = [:]
private var pidBuf: [pid_t] = []
private var pathBuf = [CChar](repeating: 0, count: 4096)
private let procLock = NSLock()

func sampleProcs() -> [ProcSample] {
    procLock.lock()
    defer { procLock.unlock() }
    let total = proc_listallpids(nil, 0)
    guard total > 0 else { return [] }
    if pidBuf.count < Int(total) + 64 { pidBuf = [pid_t](repeating: 0, count: Int(total) + 256) }
    let n = proc_listallpids(&pidBuf, Int32(pidBuf.count * MemoryLayout<pid_t>.stride))
    guard n > 0 else { return [] }
    var out: [ProcSample] = []
    out.reserveCapacity(Int(n))
    var alive = 0

    for i in 0..<min(Int(n), pidBuf.count) {
        let pid = pidBuf[i]
        var ri = rusage_info_v2()
        let ok = withUnsafeMutablePointer(to: &ri) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard ok == 0 else { continue }   // 无权限（root 进程）或已退出
        alive += 1
        let ident: Ident
        if let c = nameCache[pid] {
            ident = c
        } else {
            pathBuf[0] = 0
            var name = ""
            var path = ""
            if proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 {
                path = String(cString: pathBuf)
                name = (path as NSString).lastPathComponent
            }
            if name.isEmpty {
                pathBuf[0] = 0
                if proc_name(pid, &pathBuf, UInt32(pathBuf.count)) > 0 { name = String(cString: pathBuf) }
            }
            if name.isEmpty { name = "pid(\(pid))" }
            let (app, appPath) = appIdentity(fromPath: path, fallback: name)
            ident = Ident(name: name, app: app, appPath: appPath)
            nameCache[pid] = ident
        }
        let cpuTicks = ri.ri_user_time &+ ri.ri_system_time
        out.append(ProcSample(pid: pid, name: ident.name, app: ident.app, appPath: ident.appPath,
                              cpuNs: UInt64(Double(cpuTicks) * machToNs),
                              mem: ri.ri_phys_footprint,
                              diskR: ri.ri_diskio_bytesread,
                              diskW: ri.ri_diskio_byteswritten))
    }
    // 已退出进程的名字缓存清理（防增长 & pid 复用串名）
    if nameCache.count > alive + 64 {
        let live = Set(out.map { $0.pid })
        nameCache = nameCache.filter { live.contains($0.key) }
    }
    return out
}

struct ProcCPU {
    let p: ProcSample
    let pct: Double
    let diskRate: Double   // 读+写 B/s
    var conns: Int = 0     // 活动网络连接数
    var listens: Int = 0   // 监听端口数
}

/// 按应用汇总（一个 Electron 应用的几十个 Helper 合并成一行）
struct AppUsage {
    let name: String
    var appPath: String?
    var pct: Double
    var mem: UInt64
    var diskRate: Double
    var pids: [pid_t]
    var mainPid: pid_t
    var conns: Int = 0
    var listens: Int = 0
}

func groupByApp(_ list: [ProcCPU]) -> [AppUsage] {
    var d: [String: AppUsage] = [:]
    d.reserveCapacity(list.count / 2)
    for t in list {
        if var a = d[t.p.app] {
            a.pct += t.pct
            a.mem += t.p.mem
            a.diskRate += t.diskRate
            a.conns += t.conns
            a.listens += t.listens
            a.pids.append(t.p.pid)
            if t.p.pid < a.mainPid { a.mainPid = t.p.pid }
            if a.appPath == nil { a.appPath = t.p.appPath }
            d[t.p.app] = a
        } else {
            d[t.p.app] = AppUsage(name: t.p.app, appPath: t.p.appPath, pct: t.pct, mem: t.p.mem,
                                  diskRate: t.diskRate, pids: [t.p.pid], mainPid: t.p.pid,
                                  conns: t.conns, listens: t.listens)
        }
    }
    return d.values.sorted { $0.pct > $1.pct }
}

// MARK: - 速率计算（单调时钟差分）

struct RateMeter {
    private var prevA: UInt64 = 0, prevB: UInt64 = 0, prevT: Double = 0
    private var have = false
    /// 输入两个累计计数器，返回各自的每秒速率
    mutating func update(_ a: UInt64, _ b: UInt64) -> (Double, Double) {
        let now = monoNow()
        defer { prevA = a; prevB = b; prevT = now; have = true }
        guard have, now - prevT > 0.05 else { return (0, 0) }
        let dt = now - prevT
        let ra = a >= prevA ? Double(a - prevA) / dt : 0   // 计数器回绕/网卡重置 → 0
        let rb = b >= prevB ? Double(b - prevB) / dt : 0
        return (ra, rb)
    }
}

// MARK: - 网络（一次 sysctl 取全部网卡 64 位计数器）

struct NetSnap {
    var inRate: Double = 0
    var outRate: Double = 0
    var inTotal: UInt64 = 0
    var outTotal: UInt64 = 0
}

final class NetSampler {
    private var buf = [UInt8]()
    private var physical: [UInt16: Bool] = [:]
    private var meter = RateMeter()

    /// 只统计物理网卡 en*（Wi‑Fi / 以太网 / USB 网卡），排除 lo、utun(VPN 会重复计)、awdl 等
    private func isPhysical(_ index: UInt16) -> Bool {
        if let v = physical[index] { return v }
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
        let v = if_indextoname(UInt32(index), &name) != nil && String(cString: name).hasPrefix("en")
        physical[index] = v
        return v
    }

    func sample() -> NetSnap? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return nil }
        if buf.count < len + 2048 { buf = [UInt8](repeating: 0, count: len + 8192) }
        len = buf.count
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return nil }
        var ib: UInt64 = 0, ob: UInt64 = 0
        let hdrSize = MemoryLayout<if_msghdr>.size
        let h2Size = MemoryLayout<if_msghdr2>.size
        buf.withUnsafeBytes { raw in
            var off = 0
            while off + hdrSize <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr.self)
                let msglen = Int(hdr.ifm_msglen)
                if msglen <= 0 { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2, off + h2Size <= len {
                    let h2 = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                    if isPhysical(h2.ifm_index) {
                        ib &+= h2.ifm_data.ifi_ibytes
                        ob &+= h2.ifm_data.ifi_obytes
                    }
                }
                off += msglen
            }
        }
        if physical.count > 256 { physical.removeAll() }   // 网卡热插拔后重建
        let (ri, ro) = meter.update(ib, ob)
        return NetSnap(inRate: ri, outRate: ro, inTotal: ib, outTotal: ob)
    }
}

// MARK: - 磁盘 IO（IOKit 块设备驱动统计）

struct DiskIOSnap {
    var readRate: Double = 0
    var writeRate: Double = 0
}

final class DiskIOSampler {
    private var services: [io_object_t] = []
    private var lastRefresh = -1e9
    private var meter = RateMeter()

    deinit { services.forEach { IOObjectRelease($0) } }

    private func refresh() {
        services.forEach { IOObjectRelease($0) }
        services.removeAll()
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iter) }
        while case let s = IOIteratorNext(iter), s != 0 { services.append(s) }
        lastRefresh = monoNow()
    }

    func sample() -> DiskIOSnap {
        if monoNow() - lastRefresh > 30 { refresh() }   // 30 秒刷新一次设备列表（应对插拔）
        var r: UInt64 = 0, w: UInt64 = 0
        for s in services {
            guard let cf = IORegistryEntryCreateCFProperty(s, "Statistics" as CFString, kCFAllocatorDefault, 0),
                  let st = cf.takeRetainedValue() as? NSDictionary else { continue }
            r &+= (st["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            w &+= (st["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        let (rr, wr) = meter.update(r, w)
        return DiskIOSnap(readRate: rr, writeRate: wr)
    }
}

// MARK: - 所有磁盘卷（getfsstat MNT_NOWAIT：只读缓存，网络盘掉线不会卡）

struct Volume: Identifiable {
    var id: String { mount }
    let name: String
    let mount: String
    let fsType: String
    let total: UInt64
    let free: UInt64
    let local: Bool
    let root: Bool
    var usedFraction: Double { total > 0 ? Double(total - min(free, total)) / Double(total) : 0 }
}

private var rootVolumeName: String = {
    // 只对本地根卷查一次名字
    (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? "Macintosh HD"
}()

func listVolumes() -> [Volume] {
    let n = getfsstat(nil, 0, MNT_NOWAIT)
    guard n > 0 else { return [] }
    let blank: statfs = statfs()
    var arr: [statfs] = Array(repeating: blank, count: Int(n) + 8)
    let got = getfsstat(&arr, Int32(arr.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
    guard got > 0 else { return [] }
    let skipFS: Set<String> = ["devfs", "autofs", "nullfs", "fdesc", "mtmfs"]
    var vols: [Volume] = []
    for i in 0..<Int(got) {
        var s = arr[i]
        let mount = withUnsafeBytes(of: &s.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let fs = withUnsafeBytes(of: &s.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let isRoot = mount == "/"
        if !isRoot && (s.f_flags & UInt32(MNT_DONTBROWSE)) != 0 { continue }   // 隐藏的系统卷（Preboot/VM/Data…）
        if skipFS.contains(fs) { continue }
        let bs = UInt64(s.f_bsize)
        let total = UInt64(s.f_blocks) * bs
        if total == 0 { continue }
        vols.append(Volume(name: isRoot ? rootVolumeName : (mount as NSString).lastPathComponent,
                           mount: mount, fsType: fs, total: total, free: UInt64(s.f_bavail) * bs,
                           local: (s.f_flags & UInt32(MNT_LOCAL)) != 0, root: isRoot))
    }
    return vols.sorted { ($0.root ? 0 : 1, $0.name) < ($1.root ? 0 : 1, $1.name) }
}

// MARK: - 网络连接（libproc 套接字信息；只读内核表，不发任何网络请求）

struct Conn: Hashable, Identifiable {
    var id: String { "\(pid)-\(proto)-\(local):\(lport)-\(remote):\(rport)" }
    let pid: pid_t
    let proto: String      // TCP / UDP
    let local: String
    let lport: UInt16
    let remote: String     // 监听/未连接的为空
    let rport: UInt16
    let state: String      // 已连接 / 监听 / 正在连接 / 关闭中 / —
    let listening: Bool
}

struct ConnCount {
    var active = 0         // 有远端地址的连接（TCP 非监听 + 已 connect 的 UDP）
    var listening = 0      // 监听端口
}

private var fdBuf = [proc_fdinfo]()
private let connLock = NSLock()

private func tcpStateName(_ s: Int32) -> String {
    switch s {
    case 1: return "监听"
    case 2, 3: return "正在连接"
    case 4: return "已连接"
    case 0: return "已关闭"
    default: return "关闭中"
    }
}

private func ntop(_ ini: in_sockinfo, foreign: Bool) -> String {
    var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    if (ini.insi_vflag & UInt8(INI_IPV4)) != 0 {
        var a = foreign ? ini.insi_faddr.ina_46.i46a_addr4 : ini.insi_laddr.ina_46.i46a_addr4
        if a.s_addr == 0 { return "" }
        inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count))
    } else {
        var a = foreign ? ini.insi_faddr.ina_6 : ini.insi_laddr.ina_6
        let zero = withUnsafeBytes(of: &a) { $0.allSatisfy { $0 == 0 } }
        if zero { return "" }
        inet_ntop(AF_INET6, &a, &buf, socklen_t(buf.count))
    }
    return String(cString: buf)
}

/// 扫描一个进程的网络套接字。detail=false 时只计数（不做字符串转换，更省）。
func socketScan(pid: pid_t, detail: Bool, into conns: inout [Conn]) -> ConnCount {
    var c = ConnCount()
    let stride = MemoryLayout<proc_fdinfo>.stride
    let need = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard need > 0 else { return c }
    let n = Int(need) / stride + 32
    if fdBuf.count < n { fdBuf = [proc_fdinfo](repeating: proc_fdinfo(), count: n + 256) }
    let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fdBuf, Int32(fdBuf.count * stride))
    guard got > 0 else { return c }
    let siSize = Int32(MemoryLayout<socket_fdinfo>.size)
    for i in 0..<min(Int(got) / stride, fdBuf.count) {
        let fd = fdBuf[i]
        guard fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) else { continue }
        var si = socket_fdinfo()
        guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, siSize) == siSize else { continue }
        let s = si.psi
        guard s.soi_family == AF_INET || s.soi_family == AF_INET6 else { continue }
        let ini: in_sockinfo
        var tcpState: Int32 = -1
        if s.soi_kind == Int32(SOCKINFO_TCP) {
            ini = s.soi_proto.pri_tcp.tcpsi_ini
            tcpState = s.soi_proto.pri_tcp.tcpsi_state
        } else if s.soi_kind == Int32(SOCKINFO_IN) {
            ini = s.soi_proto.pri_in
        } else { continue }
        let isTCP = tcpState >= 0
        let fport = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_fport))
        let lport = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport))
        let listening = isTCP ? tcpState == 1 : false
        let hasRemote = fport != 0
        if listening { c.listening += 1 } else if hasRemote { c.active += 1 } else { continue }
        guard detail else { continue }
        conns.append(Conn(pid: pid, proto: isTCP ? "TCP" : "UDP",
                          local: ntop(ini, foreign: false), lport: lport,
                          remote: hasRemote ? ntop(ini, foreign: true) : "", rport: fport,
                          state: isTCP ? tcpStateName(tcpState) : (hasRemote ? "已连接" : "—"),
                          listening: listening))
    }
    return c
}

/// 所有（本用户可见）进程的连接计数
func connCounts(_ pids: [pid_t]) -> [pid_t: ConnCount] {
    connLock.lock(); defer { connLock.unlock() }
    var out: [pid_t: ConnCount] = [:]
    var dummy: [Conn] = []
    for p in pids {
        let c = socketScan(pid: p, detail: false, into: &dummy)
        if c.active + c.listening > 0 { out[p] = c }
    }
    return out
}

/// 指定进程的连接明细
func connDetails(_ pids: [pid_t]) -> [Conn] {
    connLock.lock(); defer { connLock.unlock() }
    var out: [Conn] = []
    for p in pids { _ = socketScan(pid: p, detail: true, into: &out) }
    return out
}

func serviceName(_ port: UInt16) -> String? {
    switch port {
    case 443: return "HTTPS"
    case 80: return "HTTP"
    case 53: return "DNS"
    case 22: return "SSH"
    case 5223: return "APNs"
    case 993: return "IMAP"
    case 587, 465, 25: return "SMTP"
    case 3478, 3479: return "STUN"
    case 8080, 8443: return "HTTP 代理"
    case 5228: return "Google 推送"
    case 1080: return "SOCKS"
    case 7890, 7891: return "代理"
    default: return nil
    }
}
