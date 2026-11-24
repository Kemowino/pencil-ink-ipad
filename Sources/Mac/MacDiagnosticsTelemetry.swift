import Foundation
import AppKit
import QuartzCore
import Darwin
import IOKit

/// Lightweight overlay & rendering telemetry counters (incremented only on actual draws/layouts).
@MainActor
final class MacOverlayMetrics {
    static let shared = MacOverlayMetrics()
    var overlaysMounted: Int = 0
    var committedViewsVisible: Int = 0
    var totalOverlayDrawCalls: Int = 0
    var totalOverlayLayoutCalls: Int = 0
    var totalDeferredZoomRedraws: Int = 0
    var totalPageChangeNotifications: Int = 0

    struct Snapshot {
        let overlaysMounted: Int
        let committedViewsVisible: Int
        let drawCalls: Int
        let layoutCalls: Int
        let deferredZoomRedraws: Int
        let pageChanges: Int
    }

    func snapshot() -> Snapshot {
        Snapshot(
            overlaysMounted: overlaysMounted,
            committedViewsVisible: committedViewsVisible,
            drawCalls: totalOverlayDrawCalls,
            layoutCalls: totalOverlayLayoutCalls,
            deferredZoomRedraws: totalDeferredZoomRedraws,
            pageChanges: totalPageChangeNotifications
        )
    }
}

struct MacThreadSample {
    let threadID: UInt64
    let name: String
    let cpuSeconds: Double
}

struct MacBatterySample {
    let available: Bool
    let percent: Int
    let voltageMV: Int
    let amperageMA: Int
    /// Actual Mac system load in Watts (`PowerTelemetryData.SystemLoad` on AC/Battery; falls back to battery discharge W).
    let watts: Double
    let isSystemLoadMetric: Bool
    let isCharging: Bool
    let externalConnected: Bool
}

struct MacGPUSample {
    let name: String
    let utilizationPercent: Int
}

struct MacSurfacePoolTelemetrySample {
    let hitRatePercent: Double
    let totalAllocations: UInt64
    let poolHits: UInt64
    let poolMisses: UInt64
    let pooledDraftCount: Int
    let pooledRetinaCount: Int
    let estimatedPooledMB: Double
}

/// Reads `/usr/share/pmenergy/<board-id>.plist` when readable (falling back to Intel Kaby Lake-H MacBookPro14,3 weights)
/// so Self-Test Energy Impact closely matches Activity Monitor's Intel formula (QoS CPU + 3x GPU + IDLEW wakeups).
final class MacEnergyImpactCalibrator {
    static let shared = MacEnergyImpactCalibrator()

    struct Weights {
        let boardID: String
        let sourceDescription: String
        let cpuWeight: Double
        let uiQosMultiplier: Double
        let initQosMultiplier: Double
        let defaultQosMultiplier: Double
        let utilityQosMultiplier: Double
        let backgroundQosMultiplier: Double
        let gpuWeight: Double
        let pkgIdleWakeupWeight: Double
        let timerUnder5msWeight: Double
    }

    let weights: Weights

    private init() {
        let boardID = Self.readBoardID() ?? "Mac-B4831CEBD52A0C4C"
        let plistPath = "/usr/share/pmenergy/\(boardID).plist"
        if let dict = NSDictionary(contentsOfFile: plistPath) as? [String: Any],
           let constants = dict["energy_constants"] as? [String: Any] {
            let cpuW = (constants["kcpu_time"] as? NSNumber)?.doubleValue ?? 1.0
            let gpuW = (constants["kgpu_time"] as? NSNumber)?.doubleValue ?? 3.0
            let wkW  = (constants["kcpu_wakeups"] as? NSNumber)?.doubleValue ?? 0.04
            self.weights = Weights(
                boardID: boardID,
                sourceDescription: "pmenergy(\(boardID))",
                cpuWeight: max(0.5, cpuW),
                uiQosMultiplier: 1.15,
                initQosMultiplier: 1.10,
                defaultQosMultiplier: 1.0,
                utilityQosMultiplier: 0.88,
                backgroundQosMultiplier: 0.72,
                gpuWeight: max(1.0, gpuW),
                pkgIdleWakeupWeight: max(0.0, wkW),
                timerUnder5msWeight: 0.02
            )
        } else {
            self.weights = Weights(
                boardID: boardID,
                sourceDescription: "Intel-KBL-H(\(boardID))",
                cpuWeight: 1.0,
                uiQosMultiplier: 1.15,
                initQosMultiplier: 1.10,
                defaultQosMultiplier: 1.0,
                utilityQosMultiplier: 0.88,
                backgroundQosMultiplier: 0.72,
                gpuWeight: 3.0,
                pkgIdleWakeupWeight: 0.04,
                timerUnder5msWeight: 0.02
            )
        }
    }

    func estimateEnergyImpact(
        totalCpuPct: Double,
        uiPct: Double,
        initPct: Double,
        defPct: Double,
        utilPct: Double,
        bgPct: Double,
        procGpuPct: Double,
        pkgIdleWakeupsPerSec: Double,
        timerUnder5msPerSec: Double
    ) -> Double {
        let qosSum = uiPct + initPct + defPct + utilPct + bgPct
        let unaccounted = max(0.0, totalCpuPct - qosSum)
        let weightedCpu =
            (uiPct * weights.uiQosMultiplier) +
            (initPct * weights.initQosMultiplier) +
            (defPct * weights.defaultQosMultiplier) +
            (utilPct * weights.utilityQosMultiplier) +
            (bgPct * weights.backgroundQosMultiplier) +
            unaccounted

        return max(
            0.0,
            (weightedCpu * weights.cpuWeight) +
            (procGpuPct * weights.gpuWeight) +
            (pkgIdleWakeupsPerSec * weights.pkgIdleWakeupWeight) +
            (timerUnder5msPerSec * weights.timerUnder5msWeight)
        )
    }

    private static func readBoardID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let cfVal = IORegistryEntryCreateCFProperty(service, "board-id" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return nil
        }
        if let data = cfVal as? Data {
            return String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        }
        return "\(cfVal)".trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct MacProcessSnapshot {
    let timestamp: CFTimeInterval
    let userCPUSec: Double
    let sysCPUSec: Double
    let billedSysSec: Double
    let processGPUSec: Double
    let billedEnergyRaw: UInt64
    let qosInteractiveSec: Double
    let qosInitiatedSec: Double
    let qosDefaultSec: Double
    let qosUtilitySec: Double
    let qosBackgroundSec: Double
    let physFootprintBytes: UInt64
    let pkgIdleWakeups: UInt64
    let interruptWakeups: UInt64
    let timerWakeupsUnder5ms: UInt64
    let timerWakeupsOver5ms: UInt64
    let diskReadBytes: UInt64
    let diskWriteBytes: UInt64
    let threads: [UInt64: MacThreadSample]
    let battery: MacBatterySample
    let gpus: [MacGPUSample]
    let thermalState: ProcessInfo.ThermalState
    let overlay: MacOverlayMetrics.Snapshot
    let surfacePool: MacSurfacePoolTelemetrySample

    var totalCPUSec: Double { userCPUSec + sysCPUSec }
}

struct MacIntervalMetrics {
    let durationSec: Double
    let cpuPercentTotal: Double
    let cpuPercentUser: Double
    let cpuPercentSys: Double
    let billedSysPercent: Double
    let processGPUPercent: Double
    let billedEnergyPerSec: Double
    let estimatedEnergyImpact: Double
    let pkgIdleWakeupsPerSec: Double
    let interruptWakeupsPerSec: Double
    let timerUnder5msPerSec: Double
    let timerOver5msPerSec: Double
    let memoryMB: Double
    let diskReadKBPerSec: Double
    let diskWriteKBPerSec: Double
    let qosBreakdown: String
    let topThreads: [(name: String, cpuPercent: Double)]
    let battery: MacBatterySample
    let gpus: [MacGPUSample]
    let thermalLabel: String
    let overlayDraws: Int
    let overlayLayouts: Int
    let overlaysMounted: Int
    let committedViewsVisible: Int
    let pageChanges: Int
    let fps: Double
    let p50FrameMs: Double
    let p95FrameMs: Double
    let p99FrameMs: Double
    let droppedFrames: Int
    let surfacePool: MacSurfacePoolTelemetrySample
}

/// Pure Darwin / Mach / IOKit telemetry collector (ZERO `sudo`, ZERO Metal / dGPU wakeups!).
enum MacDiagnosticsCollector {
    private static let nsPerTick: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(max(1, tb.denom))
    }()

    private static func ticksToSeconds(_ ticks: UInt64) -> Double {
        (Double(ticks) * nsPerTick) / 1_000_000_000.0
    }

    @MainActor
    static func captureSnapshot() -> MacProcessSnapshot {
        let ts = CACurrentMediaTime()

        // 1. proc_pid_rusage (RUSAGE_INFO_V4): exact CPU, QoS buckets, Memory Footprint, Idle Wakeups, Disk IO
        var rusage = rusage_info_v4()
        let rc: Int32 = withUnsafeMutablePointer(to: &rusage) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, rebound)
            }
        }

        let userSec = rc == 0 ? ticksToSeconds(rusage.ri_user_time) : 0
        let sysSec = rc == 0 ? ticksToSeconds(rusage.ri_system_time) : 0
        let billedSec = rc == 0 ? ticksToSeconds(rusage.ri_billed_system_time) : 0
        let billedEnergy = rc == 0 ? rusage.ri_billed_energy : 0
        let qosUI = rc == 0 ? ticksToSeconds(rusage.ri_cpu_time_qos_user_interactive) : 0
        let qosInit = rc == 0 ? ticksToSeconds(rusage.ri_cpu_time_qos_user_initiated) : 0
        let qosDef = rc == 0 ? ticksToSeconds(rusage.ri_cpu_time_qos_default) : 0
        let qosUtil = rc == 0 ? ticksToSeconds(rusage.ri_cpu_time_qos_utility) : 0
        let qosBg = rc == 0 ? ticksToSeconds(rusage.ri_cpu_time_qos_background) : 0

        // 2. task_info(TASK_POWER_INFO_V2): <5ms / >5ms timer bins + THIS process's exact GPU utilization nanoseconds!
        var pwr2 = task_power_info_v2_data_t()
        var pwr2Count = mach_msg_type_number_t(MemoryLayout<task_power_info_v2_data_t>.size / MemoryLayout<integer_t>.size)
        let pwr2KR: kern_return_t = withUnsafeMutablePointer(to: &pwr2) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(pwr2Count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO_V2), rebound, &pwr2Count)
            }
        }
        let bin1 = pwr2KR == KERN_SUCCESS ? pwr2.cpu_energy.task_timer_wakeups_bin_1 : 0
        let bin2 = pwr2KR == KERN_SUCCESS ? pwr2.cpu_energy.task_timer_wakeups_bin_2 : 0
        let procGPUSec = pwr2KR == KERN_SUCCESS ? Double(pwr2.gpu_energy.task_gpu_utilisation) / 1_000_000_000.0 : 0

        let threads = sampleThreads()
        let battery = sampleBattery()
        let gpus = sampleGPUs()
        let ps = MacIOSurfacePool.shared.snapshotStats()
        let poolSample = MacSurfacePoolTelemetrySample(
            hitRatePercent: ps.hitRatePercent,
            totalAllocations: ps.totalAllocations,
            poolHits: ps.poolHits,
            poolMisses: ps.poolMisses,
            pooledDraftCount: ps.pooledDraftCount,
            pooledRetinaCount: ps.pooledRetinaCount,
            estimatedPooledMB: Double(ps.estimatedPooledBytes) / (1024.0 * 1024.0)
        )

        return MacProcessSnapshot(
            timestamp: ts,
            userCPUSec: userSec,
            sysCPUSec: sysSec,
            billedSysSec: billedSec,
            processGPUSec: procGPUSec,
            billedEnergyRaw: billedEnergy,
            qosInteractiveSec: qosUI,
            qosInitiatedSec: qosInit,
            qosDefaultSec: qosDef,
            qosUtilitySec: qosUtil,
            qosBackgroundSec: qosBg,
            physFootprintBytes: rc == 0 ? rusage.ri_phys_footprint : 0,
            pkgIdleWakeups: rc == 0 ? rusage.ri_pkg_idle_wkups : 0,
            interruptWakeups: rc == 0 ? rusage.ri_interrupt_wkups : 0,
            timerWakeupsUnder5ms: bin1,
            timerWakeupsOver5ms: bin2,
            diskReadBytes: rc == 0 ? rusage.ri_diskio_bytesread : 0,
            diskWriteBytes: rc == 0 ? rusage.ri_diskio_byteswritten : 0,
            threads: threads,
            battery: battery,
            gpus: gpus,
            thermalState: ProcessInfo.processInfo.thermalState,
            overlay: MacOverlayMetrics.shared.snapshot(),
            surfacePool: poolSample
        )
    }

    static func computeInterval(
        from start: MacProcessSnapshot,
        to end: MacProcessSnapshot,
        frameDurationsMs: [Double] = []
    ) -> MacIntervalMetrics {
        let dt = max(0.05, end.timestamp - start.timestamp)

        let dUser = max(0, end.userCPUSec - start.userCPUSec)
        let dSys = max(0, end.sysCPUSec - start.sysCPUSec)
        let dBilled = max(0, end.billedSysSec - start.billedSysSec)
        let dProcGPU = max(0, end.processGPUSec - start.processGPUSec)
        let dEnergy = end.billedEnergyRaw >= start.billedEnergyRaw ? (end.billedEnergyRaw - start.billedEnergyRaw) : 0
        let energyPerSec = Double(dEnergy) / dt

        let userPct = (dUser / dt) * 100.0
        let sysPct = (dSys / dt) * 100.0
        let billedPct = (dBilled / dt) * 100.0
        let procGPUPct = (dProcGPU / dt) * 100.0
        let totalPct = userPct + sysPct

        let dPkg = end.pkgIdleWakeups >= start.pkgIdleWakeups ? (end.pkgIdleWakeups - start.pkgIdleWakeups) : 0
        let dInt = end.interruptWakeups >= start.interruptWakeups ? (end.interruptWakeups - start.interruptWakeups) : 0
        let dBin1 = end.timerWakeupsUnder5ms >= start.timerWakeupsUnder5ms ? (end.timerWakeupsUnder5ms - start.timerWakeupsUnder5ms) : 0
        let dBin2 = end.timerWakeupsOver5ms >= start.timerWakeupsOver5ms ? (end.timerWakeupsOver5ms - start.timerWakeupsOver5ms) : 0

        let pkgPerSec = Double(dPkg) / dt
        let intPerSec = Double(dInt) / dt
        let bin1PerSec = Double(dBin1) / dt
        let bin2PerSec = Double(dBin2) / dt

        let dRead = end.diskReadBytes >= start.diskReadBytes ? (end.diskReadBytes - start.diskReadBytes) : 0
        let dWrite = end.diskWriteBytes >= start.diskWriteBytes ? (end.diskWriteBytes - start.diskWriteBytes) : 0

        let qUI = max(0, end.qosInteractiveSec - start.qosInteractiveSec) / dt * 100.0
        let qInit = max(0, end.qosInitiatedSec - start.qosInitiatedSec) / dt * 100.0
        let qDef = max(0, end.qosDefaultSec - start.qosDefaultSec) / dt * 100.0
        let qUtil = max(0, end.qosUtilitySec - start.qosUtilitySec) / dt * 100.0
        let qBg = max(0, end.qosBackgroundSec - start.qosBackgroundSec) / dt * 100.0
        let qosStr = String(
            format: "UI:%.1f%% Init:%.1f%% Def:%.1f%% Util:%.1f%% Bg:%.1f%%",
            qUI, qInit, qDef, qUtil, qBg
        )

        // Calibrated pmenergy Activity Monitor Energy Impact estimate (QoS CPU + 3x GPU + IDLEW wakeups)
        let energyApprox = MacEnergyImpactCalibrator.shared.estimateEnergyImpact(
            totalCpuPct: totalPct,
            uiPct: qUI,
            initPct: qInit,
            defPct: qDef,
            utilPct: qUtil,
            bgPct: qBg,
            procGpuPct: procGPUPct,
            pkgIdleWakeupsPerSec: pkgPerSec,
            timerUnder5msPerSec: bin1PerSec
        )

        var threadDeltas: [(name: String, cpuPercent: Double)] = []
        for (tid, endT) in end.threads {
            let startCPU = start.threads[tid]?.cpuSeconds ?? 0
            let delta = max(0, endT.cpuSeconds - startCPU)
            let pct = (delta / dt) * 100.0
            if pct >= 0.15 {
                let label = endT.name.isEmpty ? "Thread #\(tid)" : endT.name
                threadDeltas.append((label, pct))
            }
        }
        threadDeltas.sort { $0.cpuPercent > $1.cpuPercent }
        let topThreads = Array(threadDeltas.prefix(6))

        var fps = 0.0
        var p50 = 0.0
        var p95 = 0.0
        var p99 = 0.0
        var dropped = 0
        if !frameDurationsMs.isEmpty {
            let sorted = frameDurationsMs.sorted()
            let avg = frameDurationsMs.reduce(0, +) / Double(frameDurationsMs.count)
            fps = avg > 0.1 ? min(120.0, 1000.0 / avg) : 0
            p50 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.50))]
            p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            p99 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
            dropped = frameDurationsMs.filter { $0 > 22.0 }.count
        }

        let thermalLabel: String
        switch end.thermalState {
        case .nominal: thermalLabel = "Nominal"
        case .fair: thermalLabel = "Fair"
        case .serious: thermalLabel = "Serious"
        case .critical: thermalLabel = "Critical"
        @unknown default: thermalLabel = "Unknown"
        }

        return MacIntervalMetrics(
            durationSec: dt,
            cpuPercentTotal: totalPct,
            cpuPercentUser: userPct,
            cpuPercentSys: sysPct,
            billedSysPercent: billedPct,
            processGPUPercent: procGPUPct,
            billedEnergyPerSec: energyPerSec,
            estimatedEnergyImpact: energyApprox,
            pkgIdleWakeupsPerSec: pkgPerSec,
            interruptWakeupsPerSec: intPerSec,
            timerUnder5msPerSec: bin1PerSec,
            timerOver5msPerSec: bin2PerSec,
            memoryMB: Double(end.physFootprintBytes) / (1024.0 * 1024.0),
            diskReadKBPerSec: Double(dRead) / 1024.0 / dt,
            diskWriteKBPerSec: Double(dWrite) / 1024.0 / dt,
            qosBreakdown: qosStr,
            topThreads: topThreads,
            battery: end.battery,
            gpus: end.gpus,
            thermalLabel: thermalLabel,
            overlayDraws: max(0, end.overlay.drawCalls - start.overlay.drawCalls),
            overlayLayouts: max(0, end.overlay.layoutCalls - start.overlay.layoutCalls),
            overlaysMounted: end.overlay.overlaysMounted,
            committedViewsVisible: end.overlay.committedViewsVisible,
            pageChanges: max(0, end.overlay.pageChanges - start.overlay.pageChanges),
            fps: fps,
            p50FrameMs: p50,
            p95FrameMs: p95,
            p99FrameMs: p99,
            droppedFrames: dropped,
            surfacePool: end.surfacePool
        )
    }

    private static let mainThreadID: UInt64 = {
        var tid: UInt64 = 0
        pthread_threadid_np(pthread_self(), &tid)
        return tid
    }()

    private static func sampleThreads() -> [UInt64: MacThreadSample] {
        var result: [UInt64: MacThreadSample] = [:]
        let mainTID = mainThreadID
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        let kr = task_threads(mach_task_self_, &threadList, &threadCount)
        guard kr == KERN_SUCCESS, let list = threadList else { return result }
        defer {
            for i in 0..<Int(threadCount) {
                mach_port_deallocate(mach_task_self_, list[i])
            }
            let size = vm_size_t(Int(threadCount) * MemoryLayout<thread_act_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: list), size)
        }

        for i in 0..<Int(threadCount) {
            let tidPort = list[i]
            var ext = thread_extended_info_data_t()
            var extCount = mach_msg_type_number_t(MemoryLayout<thread_extended_info_data_t>.size / MemoryLayout<integer_t>.size)
            let kr1: kern_return_t = withUnsafeMutablePointer(to: &ext) { ptr in
                ptr.withMemoryRebound(to: integer_t.self, capacity: Int(extCount)) {
                    thread_info(tidPort, thread_flavor_t(THREAD_EXTENDED_INFO), $0, &extCount)
                }
            }
            guard kr1 == KERN_SUCCESS else { continue }

            var idInfo = thread_identifier_info_data_t()
            var idCount = mach_msg_type_number_t(MemoryLayout<thread_identifier_info_data_t>.size / MemoryLayout<integer_t>.size)
            let kr2: kern_return_t = withUnsafeMutablePointer(to: &idInfo) { ptr in
                ptr.withMemoryRebound(to: integer_t.self, capacity: Int(idCount)) {
                    thread_info(tidPort, thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &idCount)
                }
            }
            let uniqueID = (kr2 == KERN_SUCCESS) ? idInfo.thread_id : UInt64(i)

            var name = withUnsafeBytes(of: ext.pth_name) { raw -> String in
                let bytes = raw.prefix { $0 != 0 }
                return String(decoding: bytes, as: UTF8.self)
            }
            if uniqueID == mainTID {
                name = "Main Thread"
            } else if name.isEmpty {
                name = "Worker #\(uniqueID % 1000)"
            }
            let cpuSec = Double(ext.pth_user_time + ext.pth_system_time) / 1_000_000_000.0
            result[uniqueID] = MacThreadSample(threadID: uniqueID, name: name, cpuSeconds: cpuSec)
        }
        return result
    }

    private static func sampleBattery() -> MacBatterySample {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else {
            return MacBatterySample(available: false, percent: 0, voltageMV: 0, amperageMA: 0, watts: 0, isSystemLoadMetric: false, isCharging: false, externalConnected: true)
        }
        defer { IOObjectRelease(service) }

        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = propsRef?.takeRetainedValue() as? [String: Any] else {
            return MacBatterySample(available: false, percent: 0, voltageMV: 0, amperageMA: 0, watts: 0, isSystemLoadMetric: false, isCharging: false, externalConnected: true)
        }

        let voltage = (dict["Voltage"] as? NSNumber)?.intValue ?? 0
        let amp = (dict["InstantAmperage"] as? NSNumber)?.intValue
            ?? (dict["Amperage"] as? NSNumber)?.intValue ?? 0
        let curCap = (dict["CurrentCapacity"] as? NSNumber)?.doubleValue ?? 0
        let maxCap = max(1.0, (dict["MaxCapacity"] as? NSNumber)?.doubleValue ?? 100.0)
        let pct = max(0, min(100, Int((curCap / maxCap * 100.0).rounded())))
        let charging = (dict["IsCharging"] as? Bool) ?? false
        let extConn = (dict["ExternalConnected"] as? Bool) ?? false

        var watts: Double = 0
        var isSysLoad = false
        if let ptd = dict["PowerTelemetryData"] as? [String: Any],
           let sysLoadMW = (ptd["SystemLoad"] as? NSNumber)?.doubleValue, sysLoadMW > 0 {
            watts = sysLoadMW / 1000.0
            isSysLoad = true
        } else if !extConn || amp < 0 {
            watts = (Double(voltage) * Double(abs(amp))) / 1_000_000.0
        }

        return MacBatterySample(
            available: isSysLoad || !extConn || amp < 0,
            percent: pct,
            voltageMV: voltage,
            amperageMA: amp,
            watts: watts,
            isSystemLoadMetric: isSysLoad,
            isCharging: charging,
            externalConnected: extConn
        )
    }

    private static func sampleGPUs() -> [MacGPUSample] {
        var out: [MacGPUSample] = []
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else {
            return out
        }
        defer { IOObjectRelease(iter) }

        while case let entry = IOIteratorNext(iter), entry != 0 {
            defer { IOObjectRelease(entry) }
            let statsProp = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
            let modelProp = IORegistryEntryCreateCFProperty(entry, "model" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            let classProp = IORegistryEntryCreateCFProperty(entry, "IOClass" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String

            var name = classProp ?? "GPU"
            if let s = modelProp as? String, !s.isEmpty {
                name = s
            } else if let d = modelProp as? Data {
                let s = String(decoding: d.prefix { $0 != 0 }, as: UTF8.self)
                if !s.isEmpty { name = s }
            }

            let util = (statsProp?["Device Utilization %"] as? NSNumber)?.intValue
                ?? (statsProp?["GPU Activity(%)"] as? NSNumber)?.intValue
                ?? 0
            out.append(MacGPUSample(name: name, utilizationPercent: util))
        }
        return out
    }
}
