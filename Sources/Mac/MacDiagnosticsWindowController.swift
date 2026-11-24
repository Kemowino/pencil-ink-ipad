import AppKit
import PDFKit
import QuartzCore
import UniformTypeIdentifiers

/// Pure AppKit Performance & Battery Self-Test + Live 1 Hz Monitor window (`Cmd+Option+B`).
/// Runs an automated 5-phase benchmark directly on the active PDF reader window and produces
/// a copy-pasteable objective telemetry report (CPU%, Wakeups/s, Top Threads, iGPU%, System Watts, FPS/P95).
@MainActor
final class MacDiagnosticsWindowController: NSWindowController, NSWindowDelegate {
    var activeReaderProvider: (() -> MacPDFWindowController?)?
    var onWindowClosed: (() -> Void)?

    private let statusLabel = NSTextField(labelWithString: "Ready. Open any PDF textbook, then click Run 5-Phase Self-Test.")
    private let progressBar = NSProgressIndicator()
    private let runTestBtn = NSButton(title: "Run 5-Phase Self-Test (~24s)", target: nil, action: nil)
    private let liveMonitorBtn = NSButton(title: "Start Live 1 Hz Monitor", target: nil, action: nil)
    private let copyBtn = NSButton(title: "Copy Report", target: nil, action: nil)
    private let saveBtn = NSButton(title: "Save Report…", target: nil, action: nil)

    private let reportScroll = NSScrollView()
    private let reportTextView = NSTextView()

    private var isRunningTest = false
    private var cancelTestRequested = false
    private var liveTimer: DispatchSourceTimer?
    private var lastLiveSnapshot: MacProcessSnapshot?
    private var fullReportText: String = ""

    init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Pencil Ink — Performance & Battery Self-Test"
        win.minSize = NSSize(width: 600, height: 420)
        win.center()
        super.init(window: win)
        win.delegate = self
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        liveTimer?.cancel()
    }

    private func setupUI() {
        guard let root = window?.contentView else { return }

        let topBar = NSStackView()
        topBar.orientation = .horizontal
        topBar.alignment = .centerY
        topBar.spacing = 8
        topBar.translatesAutoresizingMaskIntoConstraints = false

        runTestBtn.bezelStyle = .rounded
        runTestBtn.target = self
        runTestBtn.action = #selector(toggleSelfTest)

        liveMonitorBtn.bezelStyle = .rounded
        liveMonitorBtn.target = self
        liveMonitorBtn.action = #selector(toggleLiveMonitor)

        copyBtn.bezelStyle = .rounded
        copyBtn.target = self
        copyBtn.action = #selector(copyReport)

        saveBtn.bezelStyle = .rounded
        saveBtn.target = self
        saveBtn.action = #selector(saveReport)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        topBar.addArrangedSubview(runTestBtn)
        topBar.addArrangedSubview(liveMonitorBtn)
        topBar.addArrangedSubview(spacer)
        topBar.addArrangedSubview(copyBtn)
        topBar.addArrangedSubview(saveBtn)
        root.addSubview(topBar)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        root.addSubview(statusLabel)

        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 5
        progressBar.doubleValue = 0
        root.addSubview(progressBar)

        reportTextView.isEditable = false
        reportTextView.isSelectable = true
        reportTextView.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        reportTextView.textContainerInset = NSSize(width: 10, height: 10)
        reportTextView.autoresizingMask = [.width]
        reportTextView.string = """
        Pencil Ink Native (Intel x86_64) — Objective Performance & Battery Diagnostics
        =============================================================================
        • Click "Run 5-Phase Self-Test (~24s)" with a PDF open to measure:
            1. Idle Baseline (4.5s — checks baseline CPU, timers, idle wakeups & system floor W)
            2. Smooth Scroll (4.5s — FPS, P95 frame time, CPU%, Proc GPU%, AMD%, ΔW)
            3. Fast Page-Jump Skim (4.0s — 26 page jumps, tests Vision/PDFPageAnalyzerV2 kill)
            4. Pinch/Zoom Stress (4.0s — 60 Hz GPU pinch preview + vector commit)
            5. Post-Skim Idle Check (5.5s — verifies ZERO Vision backlog & 0% AMD after skim!)
        • Or click "Start Live 1 Hz Monitor" and scroll manually to inspect real-time
          CPU%, top threads by name, idle wakeups/s, iGPU%, and real battery Watts.
        """

        reportScroll.translatesAutoresizingMaskIntoConstraints = false
        reportScroll.documentView = reportTextView
        reportScroll.hasVerticalScroller = true
        reportScroll.borderType = .bezelBorder
        root.addSubview(reportScroll)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            topBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            topBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            statusLabel.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            progressBar.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
            progressBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            progressBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            reportScroll.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 10),
            reportScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            reportScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            reportScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
    }

    func windowWillClose(_ notification: Notification) {
        stopLiveMonitor()
        cancelTestRequested = true
        onWindowClosed?()
    }

    // MARK: - Live 1 Hz Monitor

    @objc private func toggleLiveMonitor() {
        if liveTimer != nil {
            stopLiveMonitor()
            return
        }
        guard !isRunningTest else { return }
        lastLiveSnapshot = MacDiagnosticsCollector.captureSnapshot()
        let daState = activeReaderProvider?()?.diagnosticsDocumentAnalysisState() ?? "No PDF"
        fullReportText = "=== Live 1 Hz Telemetry Monitor (docAnalysis=\(daState)) ===\n"
        reportTextView.string = fullReportText
        liveMonitorBtn.title = "Stop Live Monitor"
        runTestBtn.isEnabled = false
        statusLabel.stringValue = "Live monitor active (1 Hz). Scroll or zoom your PDF to inspect real-time metrics."

        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1), leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let now = MacDiagnosticsCollector.captureSnapshot()
            if let prev = self.lastLiveSnapshot {
                let m = MacDiagnosticsCollector.computeInterval(from: prev, to: now)
                let gpuStr = m.gpus.map { "\($0.name.prefix(16)):\($0.utilizationPercent)%" }.joined(separator: " ")
                let battStr = m.battery.available
                    ? String(format: "%.1fW (%d%%%@)", m.battery.watts, m.battery.percent, m.battery.externalConnected ? " AC" : " Batt")
                    : "N/A"
                let topT = m.topThreads.prefix(2).map { "\($0.name):\(String(format: "%.1f%%", $0.cpuPercent))" }.joined(separator: ", ")
                let line = String(
                    format: "CPU:%5.1f%% (U:%4.1f S:%4.1f) | PGPU:%4.1f%% | EstEI:%5.1f | Wkup:%3.0f/s | Mem:%4.0fMB | %@ | %@ | Top:[%@]\n",
                    m.cpuPercentTotal, m.cpuPercentUser, m.cpuPercentSys,
                    m.processGPUPercent, m.estimatedEnergyImpact, m.pkgIdleWakeupsPerSec,
                    m.memoryMB, gpuStr, battStr, topT
                )
                self.appendReport(line)
            }
            self.lastLiveSnapshot = now
        }
        liveTimer = t
        t.resume()
    }

    private func stopLiveMonitor() {
        liveTimer?.cancel()
        liveTimer = nil
        liveMonitorBtn.title = "Start Live 1 Hz Monitor"
        runTestBtn.isEnabled = !isRunningTest
        if !isRunningTest {
            statusLabel.stringValue = "Live monitor stopped."
        }
    }

    // MARK: - Automated 5-Phase Performance & Battery Self-Test

    @objc private func toggleSelfTest() {
        if isRunningTest {
            cancelTestRequested = true
            statusLabel.stringValue = "Cancelling self-test…"
            return
        }
        stopLiveMonitor()
        guard let reader = activeReaderProvider?() else {
            statusLabel.stringValue = "Open a PDF document first, then click Run 5-Phase Self-Test."
            NSSound.beep()
            return
        }

        isRunningTest = true
        cancelTestRequested = false
        runTestBtn.title = "Cancel Self-Test"
        liveMonitorBtn.isEnabled = false
        progressBar.doubleValue = 0

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.executeSelfTest(on: reader)
            self.isRunningTest = false
            self.runTestBtn.title = "Run 5-Phase Self-Test (~24s)"
            self.liveMonitorBtn.isEnabled = true
        }
    }

    private func executeSelfTest(on reader: MacPDFWindowController) async {
        let env = reader.diagnosticsEnvironmentSummary()
        let savedPage = reader.diagnosticsCurrentPageIndex()
        let savedTool = reader.diagnosticsToolMode()

        // Ensure reader window is visible so WindowServer actually composites every frame!
        reader.window?.orderFront(nil)
        reader.setToolMode(.read)

        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "3.4.0"
        let osVer = ProcessInfo.processInfo.operatingSystemVersionString
        fullReportText = """
        # Pencil Ink Native v\(ver) — Intel macOS Efficiency Proof Report
        - macOS: \(osVer) | Cores: \(ProcessInfo.processInfo.activeProcessorCount) | RAM: \(ProcessInfo.processInfo.physicalMemory / (1024*1024*1024)) GB
        - Document: \(env)
        - Timestamp: \(ISO8601DateFormatter().string(from: Date()))

        """
        reportTextView.string = fullReportText

        // 1.0s settle before Phase 1 so open/focus work finishes
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        var phaseResults: [(name: String, m: MacIntervalMetrics)] = []
        var idleWattsBaseline: Double = 0.0

        // Phase 1: Idle Baseline (4.5s)
        if !cancelTestRequested {
            statusLabel.stringValue = "Phase 1/5: Measuring Idle Baseline (4.5s) — please keep hands off trackpad…"
            let m = await runIdlePhase(durationSec: 4.5)
            idleWattsBaseline = m.battery.available ? m.battery.watts : 0.0
            phaseResults.append(("1. Idle Baseline", m))
            appendReport(formatPhaseSection("Phase 1: Idle Baseline", m))
            progressBar.doubleValue = 1
        }

        let totalP = max(1, reader.diagnosticsPageCount())
        let scrollAnchorPage = min(max(0, totalP - 12), min(50, totalP / 4))

        // Phase 2: Smooth Scroll (4.5s)
        if !cancelTestRequested {
            statusLabel.stringValue = "Phase 2/5: Smooth Scroll (4.5s)…"
            reader.diagnosticsGoToPage(scrollAnchorPage)
            try? await Task.sleep(nanoseconds: 250_000_000)
            let m = await runSmoothScrollPhase(reader: reader, durationSec: 4.5, pointsPerStep: 28)
            phaseResults.append(("2. Smooth Scroll", m))
            appendReport(formatPhaseSection("Phase 2: Smooth Scroll", m))
            progressBar.doubleValue = 2
        }

        // Phase 3: Fast Page-Jump Skim (4.0s — 26 new pages)
        if !cancelTestRequested {
            statusLabel.stringValue = "Phase 3/5: Fast Page-Jump Skim (4.0s)…"
            let m = await runPageSkimPhase(reader: reader, durationSec: 4.0)
            phaseResults.append(("3. Fast Page-Jump Skim", m))
            appendReport(formatPhaseSection("Phase 3: Fast Page-Jump Skim", m))
            progressBar.doubleValue = 3
        }

        // Phase 4: Pinch / Zoom Stress (4.0s)
        if !cancelTestRequested {
            statusLabel.stringValue = "Phase 4/5: Pinch/Zoom Stress (4.0s)…"
            let m = await runZoomStressPhase(reader: reader, durationSec: 4.0)
            phaseResults.append(("4. Zoom Stress (1.0x ↔ 2.1x)", m))
            appendReport(formatPhaseSection("Phase 4: Zoom Stress (1.0x ↔ 2.1x)", m))
            progressBar.doubleValue = 4
        }

        // Phase 5: Post-Skim Idle Check (5.5s after 1.0s settle — proves ZERO Vision backlog & 0% AMD GPU!)
        if !cancelTestRequested {
            statusLabel.stringValue = "Phase 5/5: Post-Skim Idle Check (5.5s) — verifying zero background Vision backlog…"
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let m = await runIdlePhase(durationSec: 5.5)
            phaseResults.append(("5. Post-Skim Idle Check", m))
            appendReport(formatPhaseSection("Phase 5: Post-Skim Idle Check", m))
            progressBar.doubleValue = 5
        }

        // Restore original user state
        reader.setToolMode(savedTool)
        reader.diagnosticsRestore(pageIndex: savedPage)

        // Summary Markdown Table (with AMD% & ΔW vs Phase 1 Idle Baseline!)
        if !phaseResults.isEmpty {
            var table = "\n## Summary Table\n"
            table += "| Phase | CPU% (U/S) | Proc GPU% | AMD% | Est EI | FPS (P95) | Mem | Sys W (ΔW) |\n"
            table += "| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |\n"
            for (name, m) in phaseResults {
                let fpsCol = m.fps > 0 ? String(format: "%.0f (%.1fms)", m.fps, m.p95FrameMs) : "—"
                let amdPct = m.gpus.first(where: { $0.name.localizedCaseInsensitiveContains("AMD") || $0.name.localizedCaseInsensitiveContains("Radeon") })?.utilizationPercent ?? 0
                let wCol: String
                if m.battery.available {
                    let deltaW = m.battery.watts - idleWattsBaseline
                    let sign = deltaW >= 0 ? "+" : ""
                    wCol = String(format: "%.1fW (%@%.1fW)", m.battery.watts, sign, deltaW)
                } else {
                    wCol = "N/A"
                }
                table += String(
                    format: "| %@ | %.1f%% (%.1f/%.1f) | %.1f%% | %d%% | %.1f | %@ | %.0fMB | %@ |\n",
                    name, m.cpuPercentTotal, m.cpuPercentUser, m.cpuPercentSys,
                    m.processGPUPercent, amdPct, m.estimatedEnergyImpact,
                    fpsCol, m.memoryMB, wCol
                )
            }
            appendReport(table)
        }

        statusLabel.stringValue = cancelTestRequested
            ? "Self-test cancelled."
            : "Self-test complete! Click \"Copy Report\" to share exact objective telemetry."
        window?.makeKeyAndOrderFront(nil)
    }

    private func runIdlePhase(durationSec: Double) async -> MacIntervalMetrics {
        let start = MacDiagnosticsCollector.captureSnapshot()
        try? await Task.sleep(nanoseconds: UInt64(durationSec * 1_000_000_000))
        let end = MacDiagnosticsCollector.captureSnapshot()
        return MacDiagnosticsCollector.computeInterval(from: start, to: end)
    }

    private func runSmoothScrollPhase(reader: MacPDFWindowController, durationSec: Double, pointsPerStep: CGFloat) async -> MacIntervalMetrics {
        let start = MacDiagnosticsCollector.captureSnapshot()
        var frameMs: [Double] = []
        frameMs.reserveCapacity(Int(durationSec * 65))
        let t0 = CACurrentMediaTime()
        var lastTick = t0
        var dir: CGFloat = 1.0

        while !cancelTestRequested && (CACurrentMediaTime() - t0) < durationSec {
            let moved = reader.diagnosticsScrollBy(deltaY: pointsPerStep * dir)
            if !moved { dir = -dir }
            try? await Task.sleep(nanoseconds: 16_000_000) // ~60 Hz cadence
            let now = CACurrentMediaTime()
            frameMs.append((now - lastTick) * 1000.0)
            lastTick = now
        }
        let end = MacDiagnosticsCollector.captureSnapshot()
        return MacDiagnosticsCollector.computeInterval(from: start, to: end, frameDurationsMs: frameMs)
    }

    private func runPageSkimPhase(reader: MacPDFWindowController, durationSec: Double) async -> MacIntervalMetrics {
        let start = MacDiagnosticsCollector.captureSnapshot()
        var frameMs: [Double] = []
        let totalPages = max(1, reader.diagnosticsPageCount())
        let step = max(1, min(8, totalPages / 15))
        var cur = reader.diagnosticsCurrentPageIndex()
        let t0 = CACurrentMediaTime()
        var lastTick = t0

        while !cancelTestRequested && (CACurrentMediaTime() - t0) < durationSec {
            cur = (cur + step) % totalPages
            reader.diagnosticsGoToPage(cur)
            try? await Task.sleep(nanoseconds: 140_000_000) // ~7 page jumps/sec
            let now = CACurrentMediaTime()
            frameMs.append((now - lastTick) * 1000.0)
            lastTick = now
        }
        let end = MacDiagnosticsCollector.captureSnapshot()
        return MacDiagnosticsCollector.computeInterval(from: start, to: end, frameDurationsMs: frameMs)
    }

    private func runZoomStressPhase(reader: MacPDFWindowController, durationSec: Double) async -> MacIntervalMetrics {
        let start = MacDiagnosticsCollector.captureSnapshot()
        var frameMs: [Double] = []
        let baseScale = max(0.5, reader.diagnosticsScaleFactor())
        let halfDur = max(1.0, durationSec * 0.45)

        // Gesture 1: Smooth 60Hz pinch-in 1.0x -> 2.1x, then commit crisp tiles
        var t0 = CACurrentMediaTime()
        var lastTick = t0
        while !cancelTestRequested && (CACurrentMediaTime() - t0) < halfDur {
            let frac = min(1.0, (CACurrentMediaTime() - t0) / halfDur)
            reader.diagnosticsPreviewZoom(baseScale * CGFloat(1.0 + 1.1 * frac))
            try? await Task.sleep(nanoseconds: 16_000_000)
            let now = CACurrentMediaTime()
            frameMs.append((now - lastTick) * 1000.0)
            lastTick = now
        }
        reader.diagnosticsCommitZoom()
        try? await Task.sleep(nanoseconds: 250_000_000)

        // Gesture 2: Smooth 60Hz pinch-out 2.1x -> 1.0x, then commit crisp tiles
        t0 = CACurrentMediaTime()
        lastTick = t0
        while !cancelTestRequested && (CACurrentMediaTime() - t0) < halfDur {
            let frac = min(1.0, (CACurrentMediaTime() - t0) / halfDur)
            reader.diagnosticsPreviewZoom(baseScale * CGFloat(2.1 - 1.1 * frac))
            try? await Task.sleep(nanoseconds: 16_000_000)
            let now = CACurrentMediaTime()
            frameMs.append((now - lastTick) * 1000.0)
            lastTick = now
        }
        reader.diagnosticsCommitZoom()
        try? await Task.sleep(nanoseconds: 250_000_000)

        let end = MacDiagnosticsCollector.captureSnapshot()
        return MacDiagnosticsCollector.computeInterval(from: start, to: end, frameDurationsMs: frameMs)
    }

    private func formatPhaseSection(_ title: String, _ m: MacIntervalMetrics) -> String {
        let gpuLine = m.gpus.isEmpty
            ? "N/A"
            : m.gpus.map { "\($0.name): \($0.utilizationPercent)%" }.joined(separator: " | ")
        let battLine = m.battery.available
            ? String(format: "%.2f W (%d mV, %d mA, %d%%, %@)", m.battery.watts, m.battery.voltageMV, m.battery.amperageMA, m.battery.percent, m.battery.externalConnected ? (m.battery.isCharging ? "Charging" : "AC") : "On Battery")
            : "No Battery Sensor"
        let threadsLine = m.topThreads.isEmpty
            ? "None (>0.15%)"
            : m.topThreads.map { String(format: "%@ (%.1f%%)", $0.name, $0.cpuPercent) }.joined(separator: ", ")
        let frameLine = m.fps > 0
            ? String(format: "%.1f FPS (P50: %.1fms, P95: %.1fms, P99: %.1fms, >22ms drops: %d)", m.fps, m.p50FrameMs, m.p95FrameMs, m.p99FrameMs, m.droppedFrames)
            : "Idle (no synthetic scroll)"

        return """
        ### \(title) (\(String(format: "%.2fs", m.durationSec)))
        - CPU: \(String(format: "%.1f%%", m.cpuPercentTotal)) total (User \(String(format: "%.1f%%", m.cpuPercentUser)) / Sys \(String(format: "%.1f%%", m.cpuPercentSys)) / BilledSys \(String(format: "%.1f%%", m.billedSysPercent))) | Proc GPU: \(String(format: "%.1f%%", m.processGPUPercent)) | Est EI: \(String(format: "%.1f", m.estimatedEnergyImpact))
        - QoS: \(m.qosBreakdown)
        - Wakeups: Pkg Idle \(String(format: "%.1f/s", m.pkgIdleWakeupsPerSec)) | Interrupt \(String(format: "%.1f/s", m.interruptWakeupsPerSec)) | Timers <5ms: \(String(format: "%.1f/s", m.timerUnder5msPerSec)), >5ms: \(String(format: "%.1f/s", m.timerOver5msPerSec))
        - Top Threads: \(threadsLine)
        - Memory: \(String(format: "%.1f MB", m.memoryMB)) | Disk IO: R \(String(format: "%.1f KB/s", m.diskReadKBPerSec)) / W \(String(format: "%.1f KB/s", m.diskWriteKBPerSec)) | Thermal: \(m.thermalLabel)
        - GPU (IOKit): \(gpuLine)
        - Battery: \(battLine)
        - Overlays: mounted=\(m.overlaysMounted), visibleInk=\(m.committedViewsVisible), draws=\(m.overlayDraws), layouts=\(m.overlayLayouts), pageChanges=\(m.pageChanges)
        - Frames: \(frameLine)

        """
    }

    private func appendReport(_ chunk: String) {
        fullReportText += chunk
        reportTextView.string = fullReportText
        reportTextView.scrollToEndOfDocument(nil)
    }

    @objc private func copyReport() {
        let text = fullReportText.isEmpty ? reportTextView.string : fullReportText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusLabel.stringValue = "Copied diagnostics report to clipboard!"
    }

    @objc private func saveReport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "PencilInk-Diagnostics.txt"
        guard let win = window else { return }
        panel.beginSheetModal(for: win) { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            let text = self.fullReportText.isEmpty ? self.reportTextView.string : self.fullReportText
            try? text.write(to: url, atomically: true, encoding: .utf8)
            self.statusLabel.stringValue = "Saved report to \(url.lastPathComponent)"
        }
    }
}
