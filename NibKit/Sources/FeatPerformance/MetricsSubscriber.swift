import Foundation
import MetricKit
import os
import NibContracts

// MARK: - Digests (plain values, so the formatting and history are unit-tested without MetricKit payloads)

/// A MetricKit histogram in milliseconds (launch, resume, hang and signpost durations).
struct LatencyHistogram: Codable, Equatable {
    struct Bucket: Codable, Equatable {
        var start: Double
        var end: Double
        var count: Int
    }

    var buckets: [Bucket]

    var total: Int { buckets.reduce(0) { $0 + max(0, $1.count) } }

    /// The `q` quantile (0…1), interpolated linearly inside the bucket that holds it; nil when empty.
    func percentile(_ q: Double) -> Double? {
        let filled = buckets.filter { $0.count > 0 }.sorted { $0.start < $1.start }
        let n = filled.reduce(0) { $0 + $1.count }
        guard n > 0 else { return nil }
        let target = min(max(q, 0), 1) * Double(n)
        var below = 0.0
        for b in filled {
            let upTo = below + Double(b.count)
            if target <= upTo {
                return b.start + (b.end - b.start) * ((target - below) / Double(b.count))
            }
            below = upTo
        }
        return filled.last?.end
    }
}

/// App exits MetricKit counted in one period (jetsam memory-limit kills are the memory metric that matters most).
struct ExitCounts: Codable, Equatable {
    var foregroundNormal = 0
    var foregroundMemoryLimit = 0
    var foregroundWatchdog = 0
    /// Bad access, illegal instruction and other abnormal foreground exits (crashes).
    var foregroundAbnormal = 0
    var backgroundNormal = 0
    var backgroundMemoryLimit = 0
    var backgroundMemoryPressure = 0
    var backgroundCPULimit = 0
    var backgroundWatchdog = 0
    var backgroundTaskTimeout = 0
    var backgroundLockedFile = 0
    var backgroundAbnormal = 0

    /// Exits that point at a problem (memory, watchdog, CPU, crashes): logged as errors.
    var problems: Int {
        foregroundMemoryLimit + foregroundWatchdog + foregroundAbnormal + backgroundMemoryLimit + backgroundCPULimit
            + backgroundWatchdog + backgroundTaskTimeout + backgroundLockedFile + backgroundAbnormal
    }
}

/// A custom signpost interval MetricKit aggregated (`mxSignpost`).
struct SignpostSummary: Codable, Equatable {
    var name: String
    var category: String
    var count: Int
    var duration: LatencyHistogram?
}

/// One daily `MXMetricPayload`, reduced to what the diagnostics log needs: launch, hitches, memory and the battery
/// profile (CPU, GPU, run time, disk and network).
struct MetricsDigest: Codable, Equatable {
    var begin: Date
    var end: Date
    var appVersion: String
    var osVersion: String?
    var device: String?
    var lowPowerMode: Bool?

    // Launch
    var timeToFirstDraw: LatencyHistogram?
    var optimizedTimeToFirstDraw: LatencyHistogram?
    var resume: LatencyHistogram?
    var extendedLaunch: LatencyHistogram?
    // Hitches and hangs
    var hangs: LatencyHistogram?
    /// Milliseconds of hitch per second of scrolling.
    var scrollHitchRatio: Double?
    /// Milliseconds of hitch per second of any animation (iOS 26+).
    var hitchRatio: Double?
    // Memory
    var peakMemoryMB: Double?
    var suspendedMemoryMB: Double?
    // Energy (P-095 battery and background-work profile)
    var cpuSeconds: Double?
    var gpuSeconds: Double?
    var foregroundSeconds: Double?
    var backgroundSeconds: Double?
    var backgroundAudioSeconds: Double?
    var diskWritesMB: Double?
    var wifiUpMB: Double?
    var wifiDownMB: Double?
    var cellularUpMB: Double?
    var cellularDownMB: Double?
    /// Average pixel luminance of the display while the app was on screen (APL, 0…100).
    var averagePixelLuminance: Double?
    // Exits and custom intervals
    var exits: ExitCounts?
    var signposts: [SignpostSummary] = []

    init(begin: Date, end: Date, appVersion: String) {
        self.begin = begin
        self.end = end
        self.appVersion = appVersion
    }
}

/// A crash MetricKit reported (no call stacks: the log line names the exception and signal only).
struct CrashSummary: Codable, Equatable {
    var exceptionType: Int?
    var signal: Int?
    /// Objective-C exception name (iOS 17+) or the termination reason.
    var reason: String?
}

/// One `MXDiagnosticPayload`: hangs, slow launches, CPU and disk-write exceptions, crashes.
struct DiagnosticsDigest: Codable, Equatable {
    var begin: Date
    var end: Date
    var appVersion: String?
    var hangSeconds: [Double] = []
    var launchSeconds: [Double] = []
    var cpuExceptionSeconds: [Double] = []
    var diskWriteExceptionMB: [Double] = []
    var crashes: [CrashSummary] = []

    init(begin: Date, end: Date, appVersion: String? = nil) {
        self.begin = begin
        self.end = end
        self.appVersion = appVersion
    }

    var isEmpty: Bool {
        hangSeconds.isEmpty && launchSeconds.isEmpty && cpuExceptionSeconds.isEmpty && diskWriteExceptionMB.isEmpty
            && crashes.isEmpty
    }
}

/// What the history file stores (the latest payloads, re-logged at every launch so any diagnostics export has them).
enum MetricRecord: Codable, Equatable {
    case metrics(MetricsDigest)
    case diagnostics(DiagnosticsDigest)

    /// Identity for de-duplication: MetricKit hands the same payload to `didReceive` and later to `pastPayloads`.
    var key: String {
        switch self {
        case .metrics(let d):
            return "metrics|\(d.begin.timeIntervalSince1970)|\(d.end.timeIntervalSince1970)|\(d.appVersion)"
        case .diagnostics(let d):
            return "diagnostics|\(d.begin.timeIntervalSince1970)|\(d.end.timeIntervalSince1970)|\(d.appVersion ?? "")"
                + "|\(d.hangSeconds.count)|\(d.crashes.count)|\(d.cpuExceptionSeconds.count)"
        }
    }

    var end: Date {
        switch self {
        case .metrics(let d): return d.end
        case .diagnostics(let d): return d.end
        }
    }
}

// MARK: - Formatting

/// One log line; `isProblem` lines are logged as errors (over budget, abnormal exits, crashes, hangs).
struct MetricLine: Equatable {
    var text: String
    var isProblem: Bool
}

enum MetricsFormatter {
    /// ARCHITECTURE §20: resident memory with a 1,000-page PDF open < 400 MB.
    static let memoryBudgetMB = 400.0
    /// Apple's guidance: a scroll hitch ratio above 5 ms/s is noticeable, above 10 ms/s is bad.
    static let hitchWarningRatio = 10.0

    static func lines(_ record: MetricRecord, earlier: Bool = false) -> [MetricLine] {
        switch record {
        case .metrics(let d): return lines(d, earlier: earlier)
        case .diagnostics(let d): return lines(d, earlier: earlier)
        }
    }

    static func lines(_ d: MetricsDigest, earlier: Bool = false) -> [MetricLine] {
        var head = "metrics \(period(d.begin, d.end))\(earlier ? " (earlier)" : "") app \(d.appVersion)"
        if let os = d.osVersion { head += ", \(os)" }
        if let device = d.device { head += ", \(device)" }
        if let low = d.lowPowerMode { head += low ? ", low power mode" : "" }
        var out: [MetricLine] = []

        var launch: [String] = []
        if let s = histogram("first draw", d.timeToFirstDraw, unit: "launches") { launch.append(s) }
        if let s = histogram("optimized first draw", d.optimizedTimeToFirstDraw, unit: "launches") { launch.append(s) }
        if let s = histogram("resume", d.resume, unit: "resumes") { launch.append(s) }
        if let s = histogram("extended launch", d.extendedLaunch, unit: "launches") { launch.append(s) }
        if !launch.isEmpty { out.append(MetricLine(text: head + ": launch: " + launch.joined(separator: "; "), isProblem: false)) }

        var hitches: [String] = []
        var hitchProblem = false
        if let r = d.scrollHitchRatio {
            hitches.append("scroll hitch \(number(r, digits: 1)) ms/s")
            hitchProblem = hitchProblem || r > hitchWarningRatio
        }
        if let r = d.hitchRatio {
            hitches.append("animation hitch \(number(r, digits: 1)) ms/s")
            hitchProblem = hitchProblem || r > hitchWarningRatio
        }
        if let s = histogram("hangs", d.hangs, unit: "hangs") { hitches.append(s) }
        if !hitches.isEmpty {
            out.append(MetricLine(text: head + ": hitches: " + hitches.joined(separator: "; "), isProblem: hitchProblem))
        }

        var memory: [String] = []
        var overBudget = false
        if let peak = d.peakMemoryMB {
            overBudget = peak > memoryBudgetMB
            memory.append("peak \(megabytes(peak)) (budget \(megabytes(memoryBudgetMB))\(overBudget ? ", OVER" : ""))")
        }
        if let s = d.suspendedMemoryMB { memory.append("suspended average \(megabytes(s))") }
        if let e = d.exits, e.foregroundMemoryLimit + e.backgroundMemoryLimit + e.backgroundMemoryPressure > 0 {
            memory.append("memory exits: \(e.foregroundMemoryLimit) foreground limit, \(e.backgroundMemoryLimit) background "
                          + "limit, \(e.backgroundMemoryPressure) background pressure")
        }
        if !memory.isEmpty {
            let exits = (d.exits?.foregroundMemoryLimit ?? 0) + (d.exits?.backgroundMemoryLimit ?? 0)
            out.append(MetricLine(text: head + ": memory: " + memory.joined(separator: "; "),
                                  isProblem: overBudget || exits > 0))
        }

        var energy: [String] = []
        if let v = d.cpuSeconds { energy.append("cpu \(seconds(v))") }
        if let v = d.gpuSeconds { energy.append("gpu \(seconds(v))") }
        if let v = d.foregroundSeconds { energy.append("foreground \(seconds(v))") }
        if let v = d.backgroundSeconds {
            var s = "background \(seconds(v))"
            if let a = d.backgroundAudioSeconds, a > 0 { s += " (audio \(seconds(a)))" }
            energy.append(s)
        }
        if let v = d.diskWritesMB { energy.append("disk writes \(megabytes(v))") }
        let up = (d.wifiUpMB ?? 0) + (d.cellularUpMB ?? 0)
        let down = (d.wifiDownMB ?? 0) + (d.cellularDownMB ?? 0)
        if d.wifiUpMB != nil || d.wifiDownMB != nil || d.cellularUpMB != nil || d.cellularDownMB != nil {
            energy.append("network up \(megabytes(up)), down \(megabytes(down)) "
                          + "(cellular \(megabytes((d.cellularUpMB ?? 0) + (d.cellularDownMB ?? 0))))")
        }
        if let apl = d.averagePixelLuminance { energy.append("display APL \(number(apl, digits: 0))%") }
        if !energy.isEmpty { out.append(MetricLine(text: head + ": energy: " + energy.joined(separator: ", "), isProblem: false)) }

        if let e = d.exits {
            let text = "exits: foreground \(e.foregroundNormal) normal, \(e.foregroundMemoryLimit) memory limit, "
                + "\(e.foregroundWatchdog) watchdog, \(e.foregroundAbnormal) abnormal; background \(e.backgroundNormal) "
                + "normal, \(e.backgroundMemoryPressure) memory pressure, \(e.backgroundMemoryLimit) memory limit, "
                + "\(e.backgroundCPULimit) cpu limit, \(e.backgroundTaskTimeout) task timeout, \(e.backgroundWatchdog) "
                + "watchdog, \(e.backgroundLockedFile) locked file, \(e.backgroundAbnormal) abnormal"
            out.append(MetricLine(text: head + ": " + text, isProblem: e.problems > 0))
        }

        let intervals = d.signposts.sorted { ($1.count, $0.name) < ($0.count, $1.name) }.prefix(8).map { s -> String in
            var text = "\(s.category)/\(s.name) x\(s.count)"
            if let p50 = s.duration?.percentile(0.5), let p95 = s.duration?.percentile(0.95) {
                text += " p50 \(duration(p50)) p95 \(duration(p95))"
            }
            return text
        }
        if !intervals.isEmpty {
            out.append(MetricLine(text: head + ": signposts: " + intervals.joined(separator: "; "), isProblem: false))
        }
        if out.isEmpty { out.append(MetricLine(text: head + ": no metrics in this period", isProblem: false)) }
        return out
    }

    static func lines(_ d: DiagnosticsDigest, earlier: Bool = false) -> [MetricLine] {
        var head = "diagnostics \(period(d.begin, d.end))\(earlier ? " (earlier)" : "")"
        if let v = d.appVersion { head += " app \(v)" }
        var parts: [String] = []
        if !d.hangSeconds.isEmpty {
            parts.append("\(count(d.hangSeconds.count, "hang")) (longest \(duration((d.hangSeconds.max() ?? 0) * 1000)))")
        }
        if !d.launchSeconds.isEmpty {
            parts.append("\(count(d.launchSeconds.count, "slow launch", "slow launches")) "
                         + "(longest \(duration((d.launchSeconds.max() ?? 0) * 1000)))")
        }
        if !d.cpuExceptionSeconds.isEmpty {
            parts.append("\(count(d.cpuExceptionSeconds.count, "cpu exception")) "
                         + "(\(seconds(d.cpuExceptionSeconds.reduce(0, +))) cpu)")
        }
        if !d.diskWriteExceptionMB.isEmpty {
            parts.append("\(count(d.diskWriteExceptionMB.count, "disk-write exception")) "
                         + "(\(megabytes(d.diskWriteExceptionMB.reduce(0, +))) written)")
        }
        if !d.crashes.isEmpty {
            let names = d.crashes.prefix(5).map(crashName).joined(separator: ", ")
            parts.append("\(count(d.crashes.count, "crash", "crashes")): \(names)")
        }
        guard !parts.isEmpty else { return [MetricLine(text: head + ": nothing reported", isProblem: false)] }
        return [MetricLine(text: head + ": " + parts.joined(separator: "; "), isProblem: true)]
    }

    static func crashName(_ c: CrashSummary) -> String {
        var parts: [String] = []
        if let t = c.exceptionType { parts.append(exceptionTypes[t] ?? "exception \(t)") }
        if let s = c.signal { parts.append(signals[s] ?? "signal \(s)") }
        if let r = c.reason, !r.isEmpty { parts.append(r) }
        return parts.isEmpty ? "unknown" : parts.joined(separator: " ")
    }

    /// Mach exception types (<mach/exception_types.h>).
    static let exceptionTypes: [Int: String] = [1: "EXC_BAD_ACCESS", 2: "EXC_BAD_INSTRUCTION", 3: "EXC_ARITHMETIC",
                                                4: "EXC_EMULATION", 5: "EXC_SOFTWARE", 6: "EXC_BREAKPOINT",
                                                10: "EXC_CRASH", 11: "EXC_RESOURCE", 12: "EXC_GUARD"]
    static let signals: [Int: String] = [4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 8: "SIGFPE", 9: "SIGKILL",
                                         10: "SIGBUS", 11: "SIGSEGV", 13: "SIGPIPE", 15: "SIGTERM"]

    // MARK: Units

    static func histogram(_ name: String, _ h: LatencyHistogram?, unit: String) -> String? {
        guard let h = h, let p50 = h.percentile(0.5), let p95 = h.percentile(0.95) else { return nil }
        return "\(name) p50 \(duration(p50)), p95 \(duration(p95)) (\(h.total) \(unit))"
    }

    /// Milliseconds as "412 ms" or "1.2 s".
    static func duration(_ ms: Double) -> String {
        ms < 1000 ? "\(number(ms, digits: 0)) ms" : "\(number(ms / 1000, digits: 1)) s"
    }

    static func seconds(_ s: Double) -> String { "\(number(s, digits: s < 10 ? 1 : 0)) s" }

    static func megabytes(_ mb: Double) -> String { "\(number(mb, digits: mb < 10 ? 1 : 0)) MB" }

    static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n) \(n == 1 ? singular : (plural ?? singular + "s"))"
    }

    /// Locale-independent ("." decimals), so logs read the same on every device.
    static func number(_ v: Double, digits: Int) -> String { String(format: "%.\(max(0, digits))f", v) }

    static func period(_ begin: Date, _ end: Date) -> String { "\(stamp(begin))–\(stamp(end)) UTC" }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static func stamp(_ date: Date) -> String { stampFormatter.string(from: date) }
}

// MARK: - Log and history

/// Where metric lines go: the unified log in the app ("app.nib"/"performance", which the diagnostics export reads),
/// a recorder in tests.
protocol MetricsLogSink: AnyObject {
    func write(_ line: MetricLine)
}

final class OSLogMetricsSink: MetricsLogSink {
    private let logger = Logger(subsystem: "app.nib", category: "performance")

    func write(_ line: MetricLine) {
        // Public: the lines hold numbers, versions and system names only (no note content), and diagnostics
        // exports would otherwise show "<private>".
        if line.isProblem {
            logger.error("\(line.text, privacy: .public)")
        } else {
            logger.notice("\(line.text, privacy: .public)")
        }
    }
}

/// The latest digests, in Application Support (device-local; never in the library, never uploaded). Small JSON.
final class MetricsHistory {
    static let fileName = "metrics-history.json"
    let url: URL?
    let limit: Int

    init(directory: URL?, limit: Int = 14) {
        url = directory?.appendingPathComponent(MetricsHistory.fileName)
        self.limit = limit
    }

    /// `Application Support/Nib` (next to the device id).
    static var defaultDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Nib", isDirectory: true)
    }

    func load() -> [MetricRecord] {
        guard let url = url, let data = try? Data(contentsOf: url) else { return [] }
        return (try? MetricsHistory.decoder.decode([MetricRecord].self, from: data)) ?? []
    }

    func save(_ records: [MetricRecord]) throws {
        guard let url = url else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try MetricsHistory.encoder.encode(Array(records.suffix(limit)))
        try data.write(to: url, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}

/// Logs each new digest once and keeps the latest ones for replay. Thread-safe: MetricKit delivers on its own queue.
final class MetricsRecorder {
    private let lock = NSLock()
    private let history: MetricsHistory
    private let sink: MetricsLogSink
    private var records: [MetricRecord]?
    private let log = Logger(subsystem: "app.nib", category: "performance")

    init(history: MetricsHistory, sink: MetricsLogSink) {
        self.history = history
        self.sink = sink
    }

    /// Stored digests, oldest first.
    var stored: [MetricRecord] {
        lock.lock()
        defer { lock.unlock() }
        return loaded()
    }

    /// Logs `record` and stores it; false (and nothing logged) when it was recorded before.
    @discardableResult
    func record(_ record: MetricRecord) -> Bool {
        lock.lock()
        var list = loaded()
        guard !list.contains(where: { $0.key == record.key }) else {
            lock.unlock()
            return false
        }
        list.append(record)
        list.sort { $0.end < $1.end }
        list = Array(list.suffix(history.limit))
        records = list
        do {
            try history.save(list)
        } catch {
            log.error("metrics history not saved: \(String(describing: error), privacy: .public)")
        }
        lock.unlock()
        for line in MetricsFormatter.lines(record) { sink.write(line) }
        return true
    }

    /// Re-logs every stored digest (marked "earlier"), so a diagnostics export from this launch carries the recent
    /// days too: the export reads only what this process logged. Returns the number of digests replayed.
    @discardableResult
    func replayHistory() -> Int {
        let list = stored
        for record in list {
            for line in MetricsFormatter.lines(record, earlier: true) { sink.write(line) }
        }
        return list.count
    }

    private func loaded() -> [MetricRecord] {
        if let r = records { return r }
        let r = history.load()
        records = r
        return r
    }
}

// MARK: - MetricKit

/// Receives MetricKit's daily metric and diagnostic payloads and hands their digests to the recorder.
final class MetricKitSubscriber: NSObject, MXMetricManagerSubscriber {
    static let serviceKey = "performance.metrics"
    let recorder: MetricsRecorder

    init(recorder: MetricsRecorder) {
        self.recorder = recorder
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for p in payloads { recorder.record(.metrics(MetricsDigest(p))) }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for p in payloads { recorder.record(.diagnostics(DiagnosticsDigest(p))) }
    }

    /// Subscribes, then (off the main thread) replays the stored history and records payloads MetricKit delivered
    /// before this launch subscribed.
    func start(manager: MXMetricManager = .shared) {
        manager.add(self)
        let recorder = self.recorder
        DispatchQueue.global(qos: .utility).async {
            recorder.replayHistory()
            for p in manager.pastPayloads { recorder.record(.metrics(MetricsDigest(p))) }
            for p in manager.pastDiagnosticPayloads { recorder.record(.diagnostics(DiagnosticsDigest(p))) }
        }
    }

    func stop(manager: MXMetricManager = .shared) {
        manager.remove(self)
    }
}

extension LatencyHistogram {
    init(_ h: MXHistogram<UnitDuration>) {
        var out: [Bucket] = []
        let e = h.bucketEnumerator
        while let b = e.nextObject() as? MXHistogramBucket<UnitDuration> {
            out.append(Bucket(start: b.bucketStart.converted(to: .milliseconds).value,
                              end: b.bucketEnd.converted(to: .milliseconds).value, count: b.bucketCount))
        }
        self.init(buckets: out)
    }

    /// nil for a histogram without samples, so empty categories stay out of the log.
    static func nonEmpty(_ h: MXHistogram<UnitDuration>?) -> LatencyHistogram? {
        guard let h = h else { return nil }
        let v = LatencyHistogram(h)
        return v.total > 0 ? v : nil
    }
}

extension MetricsDigest {
    init(_ p: MXMetricPayload) {
        self.init(begin: p.timeStampBegin, end: p.timeStampEnd, appVersion: p.latestApplicationVersion)
        if let meta = p.metaData {
            osVersion = meta.osVersion
            device = meta.deviceType
            lowPowerMode = meta.lowPowerModeEnabled
        }
        if let launch = p.applicationLaunchMetrics {
            timeToFirstDraw = LatencyHistogram.nonEmpty(launch.histogrammedTimeToFirstDraw)
            optimizedTimeToFirstDraw = LatencyHistogram.nonEmpty(launch.histogrammedOptimizedTimeToFirstDraw)
            resume = LatencyHistogram.nonEmpty(launch.histogrammedApplicationResumeTime)
            extendedLaunch = LatencyHistogram.nonEmpty(launch.histogrammedExtendedLaunch)
        }
        hangs = LatencyHistogram.nonEmpty(p.applicationResponsivenessMetrics?.histogrammedApplicationHangTime)
        if let animation = p.animationMetrics {
            scrollHitchRatio = animation.scrollHitchTimeRatio.value
            if #available(iOS 26, *) { hitchRatio = animation.hitchTimeRatio.value }
        }
        if let memory = p.memoryMetrics {
            peakMemoryMB = MetricsDigest.mb(memory.peakMemoryUsage)
            suspendedMemoryMB = MetricsDigest.mb(memory.averageSuspendedMemory.averageMeasurement)
        }
        cpuSeconds = p.cpuMetrics.map { $0.cumulativeCPUTime.converted(to: .seconds).value }
        gpuSeconds = p.gpuMetrics.map { $0.cumulativeGPUTime.converted(to: .seconds).value }
        if let time = p.applicationTimeMetrics {
            foregroundSeconds = time.cumulativeForegroundTime.converted(to: .seconds).value
            backgroundSeconds = time.cumulativeBackgroundTime.converted(to: .seconds).value
            backgroundAudioSeconds = time.cumulativeBackgroundAudioTime.converted(to: .seconds).value
        }
        diskWritesMB = p.diskIOMetrics.map { MetricsDigest.mb($0.cumulativeLogicalWrites) }
        if let net = p.networkTransferMetrics {
            wifiUpMB = MetricsDigest.mb(net.cumulativeWifiUpload)
            wifiDownMB = MetricsDigest.mb(net.cumulativeWifiDownload)
            cellularUpMB = MetricsDigest.mb(net.cumulativeCellularUpload)
            cellularDownMB = MetricsDigest.mb(net.cumulativeCellularDownload)
        }
        averagePixelLuminance = p.displayMetrics?.averagePixelLuminance?.averageMeasurement.value
        if let exit = p.applicationExitMetrics {
            let f = exit.foregroundExitData, b = exit.backgroundExitData
            exits = ExitCounts(
                foregroundNormal: f.cumulativeNormalAppExitCount,
                foregroundMemoryLimit: f.cumulativeMemoryResourceLimitExitCount,
                foregroundWatchdog: f.cumulativeAppWatchdogExitCount,
                foregroundAbnormal: f.cumulativeBadAccessExitCount + f.cumulativeAbnormalExitCount
                    + f.cumulativeIllegalInstructionExitCount,
                backgroundNormal: b.cumulativeNormalAppExitCount,
                backgroundMemoryLimit: b.cumulativeMemoryResourceLimitExitCount,
                backgroundMemoryPressure: b.cumulativeMemoryPressureExitCount,
                backgroundCPULimit: b.cumulativeCPUResourceLimitExitCount,
                backgroundWatchdog: b.cumulativeAppWatchdogExitCount,
                backgroundTaskTimeout: b.cumulativeBackgroundTaskAssertionTimeoutExitCount,
                backgroundLockedFile: b.cumulativeSuspendedWithLockedFileExitCount,
                backgroundAbnormal: b.cumulativeBadAccessExitCount + b.cumulativeAbnormalExitCount
                    + b.cumulativeIllegalInstructionExitCount)
        }
        signposts = (p.signpostMetrics ?? []).map { s in
            SignpostSummary(name: s.signpostName, category: s.signpostCategory, count: s.totalCount,
                            duration: LatencyHistogram.nonEmpty(s.signpostIntervalData?.histogrammedSignpostDuration))
        }
    }

    static func mb(_ m: Measurement<UnitInformationStorage>) -> Double { m.converted(to: .megabytes).value }
}

extension DiagnosticsDigest {
    init(_ p: MXDiagnosticPayload) {
        let versions = [p.hangDiagnostics?.first?.applicationVersion, p.crashDiagnostics?.first?.applicationVersion,
                        p.cpuExceptionDiagnostics?.first?.applicationVersion]
        self.init(begin: p.timeStampBegin, end: p.timeStampEnd, appVersion: versions.compactMap { $0 }.first)
        hangSeconds = (p.hangDiagnostics ?? []).map { $0.hangDuration.converted(to: .seconds).value }
        launchSeconds = (p.appLaunchDiagnostics ?? []).map { $0.launchDuration.converted(to: .seconds).value }
        cpuExceptionSeconds = (p.cpuExceptionDiagnostics ?? []).map { $0.totalCPUTime.converted(to: .seconds).value }
        diskWriteExceptionMB = (p.diskWriteExceptionDiagnostics ?? []).map {
            $0.totalWritesCaused.converted(to: .megabytes).value
        }
        crashes = (p.crashDiagnostics ?? []).map { c in
            CrashSummary(exceptionType: c.exceptionType?.intValue, signal: c.signal?.intValue,
                         reason: c.exceptionReason?.exceptionName ?? c.terminationReason)
        }
    }
}
