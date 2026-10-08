import Foundation
import IOKit
import IOKit.ps
import Darwin

// MARK: - SMC (fans / temperatures)
final class SMC {
    struct Vers { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
    struct PLimit { var version: UInt16 = 0, length: UInt16 = 0, cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0 }
    struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0, dataAttributes: UInt8 = 0, p1: UInt8 = 0, p2: UInt8 = 0, p3: UInt8 = 0 }
    struct KeyData {
        var key: UInt32 = 0; var vers = Vers(); var pLimit = PLimit(); var keyInfo = KeyInfo()
        var result: UInt8 = 0; var status: UInt8 = 0; var data8: UInt8 = 0; var data32: UInt32 = 0
        var bytes: (UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                    UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8) =
            (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    }
    static let shared = SMC()
    var conn: io_connect_t = 0
    var infoCache: [UInt32: KeyInfo] = [:]

    init() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        if svc != 0 { IOServiceOpen(svc, mach_task_self_, 0, &conn); IOObjectRelease(svc) }
    }
    static func code(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    func call(_ inp: inout KeyData) -> KeyData? {
        var out = KeyData(); var size = MemoryLayout<KeyData>.size
        let r = IOConnectCallStructMethod(conn, 2, &inp, MemoryLayout<KeyData>.size, &out, &size)
        return r == kIOReturnSuccess && out.result == 0 ? out : nil
    }
    func info(_ key: UInt32) -> KeyInfo? {
        if let i = infoCache[key] { return i }
        var d = KeyData(); d.key = key; d.data8 = 9
        guard let o = call(&d) else { return nil }
        infoCache[key] = o.keyInfo; return o.keyInfo
    }
    func read(_ name: String) -> Double? {
        guard conn != 0 else { return nil }
        let key = SMC.code(name); guard let i = info(key), i.dataSize > 0 else { return nil }
        var d = KeyData(); d.key = key; d.keyInfo = i; d.data8 = 5
        guard let o = call(&d) else { return nil }
        let b = withUnsafeBytes(of: o.bytes) { Array($0.prefix(Int(i.dataSize))) }
        switch i.dataType {
        case SMC.code("flt "): return b.count >= 4 ? Double(b.withUnsafeBytes { $0.load(as: Float.self) }) : nil
        case SMC.code("fpe2"): return b.count >= 2 ? Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4 : nil
        case SMC.code("sp78"): return b.count >= 2 ? Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256 : nil
        case SMC.code("ui8 "): return Double(b[0])
        case SMC.code("ui16"): return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case SMC.code("ui32"): return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        default: return nil
        }
    }
    func write(_ name: String, _ value: Double) -> Bool {
        guard conn != 0 else { return false }
        let key = SMC.code(name); guard let i = info(key), i.dataSize > 0 else { return false }
        var d = KeyData(); d.key = key; d.keyInfo = i; d.data8 = 6
        var b = [UInt8](repeating: 0, count: 32)
        switch i.dataType {
        case SMC.code("flt "): withUnsafeBytes(of: Float(value)) { for (j, x) in $0.enumerated() { b[j] = x } }
        case SMC.code("fpe2"): let v = UInt16(value * 4); b[0] = UInt8(v >> 8); b[1] = UInt8(v & 0xff)
        case SMC.code("ui8 "): b[0] = UInt8(max(0, min(255, value)))
        case SMC.code("ui16"): let v = UInt16(value); b[0] = UInt8(v >> 8); b[1] = UInt8(v & 0xff)
        default: return false
        }
        withUnsafeMutableBytes(of: &d.bytes) { for j in 0..<32 { $0[j] = b[j] } }
        return call(&d) != nil
    }
    func fanMode(_ i: Int) -> Int { Int(read("F\(i)Md") ?? 0) }   // 0 auto, 1 manual
    func fanRange(_ i: Int) -> (Double, Double) { (read("F\(i)Mn") ?? 0, read("F\(i)Mx") ?? 0) }
    /// rpm == nil -> automatic
    func setFan(_ i: Int, rpm: Double?) -> Bool {
        if let r = rpm {
            let (lo, hi) = fanRange(i); let t = max(lo, min(hi, r))
            return write("F\(i)Md", 1) && write("F\(i)Tg", t)
        }
        return write("F\(i)Md", 0)
    }
    func fans() -> [(rpm: Double, max: Double)] {
        let n = Int(read("FNum") ?? 0); return (0..<n).map { (read("F\($0)Ac") ?? 0, read("F\($0)Mx") ?? 0) }
    }
    // Apple Silicon temperature keys (varies by chip; we probe and keep plausible ones)
    static let tempKeys: [(String, String)] = [
        ("Tp01","CPU P1"),("Tp05","CPU P2"),("Tp09","CPU P3"),("Tp0D","CPU P4"),("Tp0H","CPU P5"),("Tp0L","CPU P6"),("Tp0P","CPU P7"),("Tp0T","CPU P8"),
        ("Tp0X","CPU P9"),("Tp0b","CPU P10"),("Tp0f","CPU P11"),("Tp0j","CPU P12"),
        ("Te05","CPU E1"),("Te0L","CPU E2"),("Te0P","CPU E3"),("Te0S","CPU E4"),
        ("Tf04","GPU 1"),("Tf09","GPU 2"),("Tf0A","GPU 3"),("Tf0B","GPU 4"),("Tf0D","GPU 5"),("Tf0E","GPU 6"),("Tf44","GPU 7"),("Tf49","GPU 8"),("Tf4A","GPU 9"),("Tf4B","GPU 10"),("Tf4D","GPU 11"),("Tf4E","GPU 12"),
        ("Tg05","GPU A"),("Tg0D","GPU B"),("Tg0L","GPU C"),("Tg0T","GPU D"),
        ("TB1T","Battery"),("TB2T","Battery 2"),("TW0P","Airport"),("Ts0P","Palm rest"),("Ts1P","Palm rest 2"),("TH0x","SSD"),("TaLP","Ambient L"),("TaRF","Ambient R"),("TPMP","PMU"),("Tm02","Mem")
    ]
    func temps() -> [(String, Double)] {
        SMC.tempKeys.compactMap { k, n in if let v = read(k), v > 5, v < 125, v != 40.0 { return (n, v) } else { return nil } }
    }
}

// MARK: - System metrics
struct Snapshot {
    var cpu = 0.0, cpuCores: [Double] = [], memUsed = 0.0, memTotal = 0.0, swap = 0.0
    var diskUsed = 0.0, diskTotal = 0.0, uptime = 0.0, load = (0.0, 0.0, 0.0)
    var netIn = 0.0, netOut = 0.0, battery = -1, charging = false, timeLeft = -1
    var fans: [(rpm: Double, max: Double)] = [], fanManual = false, temps: [(String, Double)] = [], procs: [(String, Double)] = []
    var thermal = "", chip = "", wifi = "", ip = ""

    var summary: String {
        var s = "Chip \(chip). CPU \(Int(cpu))%, load \(String(format: "%.1f/%.1f/%.1f", load.0, load.1, load.2)). "
        s += "Memory \(String(format: "%.1f", memUsed))/\(Int(memTotal)) GB, swap \(String(format: "%.1f", swap)) GB. "
        s += "Disk \(Int(diskUsed))/\(Int(diskTotal)) GB. Uptime \(Stats.fmtUptime(uptime)). Thermal \(thermal). "
        if battery >= 0 { s += "Battery \(battery)%\(charging ? " charging" : "")\(timeLeft > 0 ? ", \(timeLeft) min left" : ""). " }
        s += "Net ↓\(Stats.fmtBytes(netIn))/s ↑\(Stats.fmtBytes(netOut))/s, IP \(ip)\(wifi.isEmpty ? "" : ", Wi‑Fi \(wifi)"). "
        if !fans.isEmpty { s += "Fans (\(fanManual ? "MANUAL" : "AUTO") mode) " + fans.map { "\(Int($0.rpm)) rpm" }.joined(separator: ", ") + ", max \(Int(fans[0].max)) rpm. " }
        if !temps.isEmpty { s += "Temps " + temps.map { "\($0.0) \(Int($0.1))°C" }.joined(separator: ", ") + ". " }
        s += "Top processes " + procs.prefix(5).map { "\($0.0) \(Int($0.1))%" }.joined(separator: ", ") + "."
        return s
    }
}

final class Stats {
    static let shared = Stats()
    var prevCPU: [UInt32] = [], prevNet = (0.0, 0.0), prevTime = Date()
    var snap = Snapshot()
    let chip: String = { var sz = 0; sysctlbyname("machdep.cpu.brand_string", nil, &sz, nil, 0); var b = [CChar](repeating: 0, count: sz); sysctlbyname("machdep.cpu.brand_string", &b, &sz, nil, 0); return String(cString: b) }()

    static func fmtBytes(_ b: Double) -> String {
        b > 1e9 ? String(format: "%.1f GB", b/1e9) : b > 1e6 ? String(format: "%.1f MB", b/1e6) : b > 1e3 ? String(format: "%.0f KB", b/1e3) : String(format: "%.0f B", b)
    }
    static func fmtUptime(_ s: Double) -> String { let d = Int(s)/86400, h = Int(s)%86400/3600, m = Int(s)%3600/60; return d > 0 ? "\(d)d \(h)h \(m)m" : "\(h)h \(m)m" }

    func refresh() -> Snapshot {
        var s = Snapshot(); s.chip = chip
        // CPU per core
        var nCPU: natural_t = 0, info: processor_info_array_t? = nil, count: mach_msg_type_number_t = 0
        if host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &nCPU, &info, &count) == KERN_SUCCESS, let info = info {
            let n = Int(nCPU) * Int(CPU_STATE_MAX)
            let cur = (0..<n).map { UInt32(bitPattern: info[$0]) }
            if prevCPU.count == n {
                var totalBusy = 0.0, totalAll = 0.0
                for c in 0..<Int(nCPU) {
                    let b = c * Int(CPU_STATE_MAX)
                    let user = Double(cur[b] &- prevCPU[b]), sys = Double(cur[b+1] &- prevCPU[b+1]), idle = Double(cur[b+2] &- prevCPU[b+2]), nice = Double(cur[b+3] &- prevCPU[b+3])
                    let busy = user + sys + nice, all = busy + idle
                    s.cpuCores.append(all > 0 ? busy / all * 100 : 0); totalBusy += busy; totalAll += all
                }
                s.cpu = totalAll > 0 ? totalBusy / totalAll * 100 : 0
            }
            prevCPU = cur
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.size))
        }
        // Memory
        var vm = vm_statistics64(); var vc = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        withUnsafeMutablePointer(to: &vm) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(vc)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vc) } }
        let page = Double(vm_kernel_page_size)
        s.memTotal = Double(ProcessInfo.processInfo.physicalMemory) / 1e9
        s.memUsed = (Double(vm.active_count + vm.wire_count + vm.compressor_page_count) * page) / 1e9
        var sw = xsw_usage(); var swsz = MemoryLayout<xsw_usage>.size; sysctlbyname("vm.swapusage", &sw, &swsz, nil, 0); s.swap = Double(sw.xsu_used) / 1e9
        // Disk
        if let a = try? FileManager.default.attributesOfFileSystem(forPath: "/") {
            s.diskTotal = (a[.systemSize] as? Double ?? 0) / 1e9; s.diskUsed = s.diskTotal - (a[.systemFreeSize] as? Double ?? 0) / 1e9
        }
        // Uptime / load
        s.uptime = ProcessInfo.processInfo.systemUptime
        var l = [Double](repeating: 0, count: 3); getloadavg(&l, 3); s.load = (l[0], l[1], l[2])
        s.thermal = ["Nominal", "Fair", "Serious", "Critical"][ProcessInfo.processInfo.thermalState.rawValue]
        // Network
        var ifa: UnsafeMutablePointer<ifaddrs>? = nil; var tin = 0.0, tout = 0.0
        if getifaddrs(&ifa) == 0 {
            var p = ifa
            while let i = p {
                let name = String(cString: i.pointee.ifa_name)
                if i.pointee.ifa_addr.pointee.sa_family == UInt8(AF_LINK), name.hasPrefix("en"), let d = i.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                    tin += Double(d.pointee.ifi_ibytes); tout += Double(d.pointee.ifi_obytes)
                }
                if i.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET), name == "en0" {
                    var h = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(i.pointee.ifa_addr, socklen_t(i.pointee.ifa_addr.pointee.sa_len), &h, socklen_t(h.count), nil, 0, NI_NUMERICHOST); s.ip = String(cString: h)
                }
                p = i.pointee.ifa_next
            }
            freeifaddrs(ifa)
        }
        let dt = max(Date().timeIntervalSince(prevTime), 0.1)
        if prevNet.0 > 0 { s.netIn = (tin - prevNet.0) / dt; s.netOut = (tout - prevNet.1) / dt }
        prevNet = (tin, tout); prevTime = Date()
        // Battery
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list { if let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any] {
                s.battery = d[kIOPSCurrentCapacityKey] as? Int ?? -1; s.charging = d[kIOPSIsChargingKey] as? Bool ?? false
                s.timeLeft = d[kIOPSTimeToEmptyKey] as? Int ?? -1 } }
        }
        s.fans = SMC.shared.fans(); s.temps = SMC.shared.temps()
        s.fanManual = !s.fans.isEmpty && SMC.shared.fanMode(0) == 1
        s.wifi = snap.wifi // filled by background task
        s.procs = snap.procs
        snap = s
        return s
    }

    // slower stuff off the main thread
    func refreshSlow() {
        let out = shell("/bin/ps", ["-Aceo", "pcpu,comm", "-r"]).split(separator: "\n").dropFirst().prefix(8)
        let procs: [(String, Double)] = out.compactMap { l in
            let p = l.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1); guard p.count == 2, let v = Double(p[0]) else { return nil }
            return (String(p[1]).components(separatedBy: "/").last ?? "", v)
        }
        let wifi = shell("/usr/sbin/ipconfig", ["getsummary", "en0"]).split(separator: "\n").first { $0.contains(" SSID : ") }.map { $0.components(separatedBy: " SSID : ").last!.trimmingCharacters(in: .whitespaces) } ?? ""
        DispatchQueue.main.async { self.snap.procs = procs; self.snap.wifi = wifi }
    }
    func shell(_ path: String, _ args: [String]) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = nil
        try? p.run(); let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(data: d, encoding: .utf8) ?? ""
    }
}
