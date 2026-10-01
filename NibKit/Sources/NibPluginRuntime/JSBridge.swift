import Foundation
import JavaScriptCore
import NibContracts

/// One plugin's JavaScript engine: a `JSVirtualMachine` and `JSContext` that are only ever touched on `queue`, the
/// plugin's own serial queue. It knows nothing about commands: native calls from the prelude are handed to the
/// owner through the `on…` callbacks (on `queue`), and the owner answers with `reply(_:ok:json:)` from any thread.
///
/// Watchdog: every entry into JavaScript is timed. When one runs longer than its limit the owner is told through
/// `onHang` (from a utility queue); where JavaScriptCore exports `JSContextGroupSetExecutionTimeLimit` (looked up
/// with dlsym, not public API) the runaway script is also terminated, so the queue comes back. Without it a hung
/// thread leaks until relaunch (ARCHITECTURE.md §21).
final class JSBridge {
    /// A command-bus call from JavaScript: method, JSON arguments, entry token ("" = none) and the reply number.
    typealias CallHandler = (_ method: String, _ argsJSON: String, _ callID: String, _ reply: Int) -> Void

    let pluginID: String
    let queue: DispatchQueue
    let timers: PluginTimers

    /// Called on `queue`.
    var onCall: CallHandler?
    /// A command handler, event callback or console evaluation finished: token, ok, JSON value or error. On `queue`.
    var onDone: ((_ token: String, _ ok: Bool, _ json: String) -> Void)?
    /// console.* and runtime notes. On `queue`.
    var onLog: ((_ level: String, _ text: String) -> Void)?
    /// `events.on` / unsubscribe: type, wants own events, +1 / -1. On `queue`.
    var onSubscribe: ((_ type: String, _ includeOwn: Bool, _ delta: Int) -> Void)?
    /// An entry into JavaScript ran past its limit (seconds). From a background queue.
    var onHang: ((_ seconds: TimeInterval) -> Void)?

    // Queue-confined.
    private var vm: JSVirtualMachine?
    private var context: JSContext?
    private var dispatch: JSValue?
    private var replies: [Int: (resolve: JSValue, reject: JSValue)] = [:]
    private var nextReply = 0
    private var isShutDown = false

    // Watchdog state (any thread).
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var busy = false
    private var busyStart = DispatchTime.now()
    private var limit: TimeInterval

    /// How long one entry into JavaScript may run when no caller gives its own limit (timer callbacks, promise
    /// continuations after a reply). The owner raises it while a `longRunning` command is in flight.
    var defaultLimit: TimeInterval {
        get {
            lock.lock()
            defer { lock.unlock() }
            return limit
        }
        set {
            lock.lock()
            limit = newValue
            lock.unlock()
        }
    }

    init(pluginID: String, maxTimers: Int, defaultLimit: TimeInterval) {
        self.pluginID = pluginID
        let queue = DispatchQueue(label: "app.nib.plugin." + pluginID, qos: .userInitiated)
        self.queue = queue
        self.timers = PluginTimers(queue: queue, maxTimers: maxTimers)
        self.limit = defaultLimit
    }

    /// True while JavaScript runs on `queue` (tests and diagnostics).
    var isBusy: Bool {
        lock.lock()
        defer { lock.unlock() }
        return busy
    }

    /// How long the current entry into JavaScript has been running (0 when idle).
    var busySeconds: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard busy else { return 0 }
        return Double(DispatchTime.now().uptimeNanoseconds - busyStart.uptimeNanoseconds) / 1_000_000_000
    }

    // MARK: Boot

    /// `boot` on `queue`: `source` loads the entry bundle there; `completion` runs on `queue`.
    func bootAsync(prelude: String, info: String, source: @escaping () throws -> String, sourceURL: URL?, limit: TimeInterval,
                   completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            completion(Result { try self.boot(prelude: prelude, info: info, source: source(), sourceURL: sourceURL, limit: limit) })
        }
    }

    /// Creates the VM and context, runs the prelude with `info` and evaluates the entry bundle. Call on `queue`.
    func boot(prelude: String, info: String, source: String, sourceURL: URL?, limit: TimeInterval) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let vm = JSVirtualMachine(), let context = JSContext(virtualMachine: vm) else {
            throw NibError(.internalError, "JavaScriptCore could not create a context")
        }
        context.name = "plugin:" + pluginID
        self.vm = vm
        self.context = context
        timers.fire = { [weak self] id in
            guard let self = self, !self.isShutDown else { return }
            self.enter(limit: self.defaultLimit) { bridge in
                _ = bridge.dispatch?.invokeMethod("fire", withArguments: [id])
            }
        }
        var bootError: Error?
        enter(limit: limit) { bridge in
            do {
                try bridge.installPrelude(prelude, info: info, in: context)
                context.exception = nil
                context.evaluateScript(source, withSourceURL: sourceURL)
                if let exception = context.exception {
                    context.exception = nil
                    throw NibError(.invalidParams, "\(sourceURL?.lastPathComponent ?? "the entry script") failed: " + JSBridge.describe(exception),
                                   path: "$.entry", hint: "fix the script, then reload the plugin; plugin.logs shows its console")
                }
            } catch {
                bootError = error
            }
        }
        if let error = bootError { throw error }
    }

    private func installPrelude(_ prelude: String, info: String, in context: JSContext) throws {
        guard let natives = JSValue(newObjectIn: context) else {
            throw NibError(.internalError, "JavaScriptCore could not create the native bridge object")
        }
        let call: @convention(block) (String, String, String, JSValue, JSValue) -> Void = { [weak self] method, args, callID, resolve, reject in
            self?.receiveCall(method: method, args: args, callID: callID, resolve: resolve, reject: reject)
        }
        let log: @convention(block) (String, String) -> Void = { [weak self] level, text in
            self?.onLog?(level, text)
        }
        let done: @convention(block) (String, Bool, String) -> Void = { [weak self] token, ok, json in
            self?.onDone?(token, ok, json)
        }
        let timer: @convention(block) (String, Double, Double, Bool) -> Bool = { [weak self] op, id, ms, repeats in
            guard let self = self else { return false }
            switch op {
            case "set": return self.timers.set(id: Int(id), milliseconds: ms, repeats: repeats)
            default:
                self.timers.clear(id: Int(id))
                return true
            }
        }
        let subscribe: @convention(block) (String, Bool, Double) -> Void = { [weak self] type, includeOwn, delta in
            self?.onSubscribe?(type, includeOwn, delta < 0 ? -1 : 1)
        }
        natives.setObject(unsafeBitCast(call, to: AnyObject.self), forKeyedSubscript: "__nib_call" as NSString)
        natives.setObject(unsafeBitCast(log, to: AnyObject.self), forKeyedSubscript: "__nib_log" as NSString)
        natives.setObject(unsafeBitCast(done, to: AnyObject.self), forKeyedSubscript: "__nib_done" as NSString)
        natives.setObject(unsafeBitCast(timer, to: AnyObject.self), forKeyedSubscript: "__nib_timer" as NSString)
        natives.setObject(unsafeBitCast(subscribe, to: AnyObject.self), forKeyedSubscript: "__nib_subscribe" as NSString)

        context.exception = nil
        let factory = context.evaluateScript(prelude, withSourceURL: URL(string: "nib-plugin://" + pluginID + "/nib-prelude.js"))
        if let exception = context.exception {
            context.exception = nil
            throw NibError(.internalError, "the plugin prelude failed: " + JSBridge.describe(exception))
        }
        guard let factory = factory, factory.isObject,
              let table = factory.call(withArguments: [context.globalObject as Any, natives, info]), table.isObject else {
            let detail = context.exception.map { JSBridge.describe($0) } ?? "no dispatch table"
            context.exception = nil
            throw NibError(.internalError, "the plugin prelude failed: " + detail)
        }
        dispatch = table
    }

    // MARK: Entering JavaScript

    /// Runs `work` on `queue` as one timed entry into JavaScript.
    func perform(limit: TimeInterval, _ work: @escaping (JSBridge) -> Void) {
        queue.async { [weak self] in
            guard let self = self, !self.isShutDown else { return }
            self.enter(limit: limit, work)
        }
    }

    /// Calls a function of the prelude's dispatch table (`invoke`, `event`, `evaluate`) on `queue`.
    func callDispatch(_ name: String, _ arguments: [Any], limit: TimeInterval) {
        perform(limit: limit) { bridge in
            _ = bridge.dispatch?.invokeMethod(name, withArguments: arguments)
        }
    }

    /// Must run on `queue`: arms the watchdog (and JavaScriptCore's own time limit), runs `work`, reports uncaught
    /// exceptions and entries that ran past `limit`.
    private func enter(limit: TimeInterval, _ work: (JSBridge) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let context = context else { return }
        lock.lock()
        generation &+= 1
        let current = generation
        busy = true
        busyStart = .now()
        lock.unlock()
        let watchdog = DispatchWorkItem { [weak self] in self?.checkHang(generation: current, limit: limit) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + limit, execute: watchdog)
        JSBridge.setExecutionTimeLimit(context, seconds: limit)
        let started = DispatchTime.now()
        context.exception = nil
        work(self)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000_000
        watchdog.cancel()
        lock.lock()
        busy = false
        lock.unlock()
        if let exception = context.exception {
            context.exception = nil
            onLog?("error", "uncaught: " + JSBridge.describe(exception))
        }
        // JavaScriptCore's time limit terminated a runaway script (or it finished just past the limit): a hang.
        if elapsed >= limit * 0.98 { onHang?(elapsed) }
    }

    private func checkHang(generation expected: UInt64, limit: TimeInterval) {
        lock.lock()
        let hung = busy && generation == expected
        lock.unlock()
        if hung { onHang?(limit) }
    }

    // MARK: Native calls and replies

    private func receiveCall(method: String, args: String, callID: String, resolve: JSValue, reject: JSValue) {
        nextReply += 1
        let number = nextReply
        replies[number] = (resolve, reject)
        guard let handler = onCall else {
            replies[number] = nil
            _ = reject.call(withArguments: [JSBridge.errorJSON(NibError.unavailable("the plugin runtime"))])
            return
        }
        handler(method, args, callID, number)
    }

    /// Settles the promise of native call `number` with a JSON value (ok) or NibError JSON. Any thread.
    func reply(_ number: Int, ok: Bool, json: String) {
        perform(limit: defaultLimit) { bridge in
            guard let pair = bridge.replies.removeValue(forKey: number) else { return }
            _ = (ok ? pair.resolve : pair.reject).call(withArguments: [json])
        }
    }

    /// Stops timers and releases the engine (on `queue`, so a hung thread keeps its context until it returns).
    func shutdown() {
        timers.cancelAll()
        queue.async { [weak self] in
            guard let self = self else { return }
            self.isShutDown = true
            self.replies.removeAll()
            self.dispatch = nil
            self.context = nil
            self.vm = nil
        }
    }

    // MARK: Helpers

    /// The `{code, message, path?, hint?}` JSON a rejected promise carries into JavaScript.
    static func errorJSON(_ error: NibError) -> String {
        (error.json["error"] ?? ["code": "internal", "message": .string(error.message)]).jsonString()
    }

    static func describe(_ exception: JSValue) -> String {
        var text = exception.toString() ?? "unknown JavaScript error"
        if let line = exception.objectForKeyedSubscript("line"), line.isNumber {
            text += " (line \(line.toInt32()))"
        }
        return text
    }

    /// `JSContextGroupSetExecutionTimeLimit(group, limit, callback, data)` from JavaScriptCore's private API, when the
    /// running JavaScriptCore exports it. A nil callback means "terminate when the limit is reached".
    private typealias SetTimeLimit = @convention(c) (OpaquePointer?, Double, OpaquePointer?, UnsafeMutableRawPointer?) -> Void

    private static let setTimeLimit: SetTimeLimit? = {
        // RTLD_DEFAULT: search every image loaded in the process.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit") else {
            return nil
        }
        return unsafeBitCast(symbol, to: SetTimeLimit.self)
    }()

    /// True when runaway scripts are terminated by JavaScriptCore (not only reported by the watchdog).
    static var terminatesRunawayScripts: Bool { setTimeLimit != nil }

    private static func setExecutionTimeLimit(_ context: JSContext, seconds: TimeInterval) {
        guard let set = setTimeLimit, let global = context.jsGlobalContextRef else { return }
        set(JSContextGetGroup(global), seconds, nil, nil)
    }
}
