import Foundation
import UIKit
import os
import NibContracts

// MARK: - The injected `window.nib`

/// The script injected at document start into a plugin panel's main frame. It builds the same `nib.*` API as the
/// plugin runtime's prelude.js (docs/PLUGIN_API.md §4), plus the panel additions of §5.5: `nib.onMessage(fn)`
/// (what main.js sends with `nib.ui.postToPanel`) and `nib.postMessage(msg)` (a `plugin.message` to main.js), and
/// `nib.panel` ({id, params}: the `panel.open` params).
///
/// Every call crosses one `WKScriptMessageHandlerWithReply` named `nibPanel` as `{method, args: <JSON text>}` and
/// comes back as JSON text (or an error string holding `{code, message, path?, hint?}` JSON), routed by `PanelBridge`
/// to the command bus as principal `plugin:<id>`. Nib pushes into the page through `__nibPanelHost.receive(kind,
/// json)`: "message", "event", "settings" and "tokens" (NibWebTokens CSS, inside `@layer nib` so the plugin's own
/// unlayered CSS always wins).
enum PanelBridgeScript {
    static let handlerName = "nibPanel"
    static let hostObject = "__nibPanelHost"

    /// The full user script: the bootstrap function applied to `info` (plain JSON, so it is a JavaScript literal).
    static func source(info: JSONValue) -> String {
        bootstrap + "(" + info.jsonString() + ");\n"
    }

    /// Calls `__nibPanelHost.receive(kind, json)`; the values arrive as `callAsyncJavaScript` arguments, never as source.
    static let receiveCall = "if (window.\(hostObject)) { window.\(hostObject).receive(kind, json); }"

    /// Runs in every frame before the page: peer-to-peer WebRTC would reach hosts no content rule can see, so its
    /// constructors are removed (a plugin panel has no permission that covers it).
    static let networkGuard = #"""
    (function () {
      "use strict";
      var names = ["RTCPeerConnection", "webkitRTCPeerConnection", "RTCDataChannel", "RTCIceCandidate",
                   "RTCSessionDescription", "RTCRtpSender", "RTCRtpReceiver", "RTCRtpTransceiver"];
      for (var i = 0; i < names.length; i++) {
        try { Object.defineProperty(window, names[i], { value: undefined, writable: false, configurable: false }); } catch (_) {}
      }
    })();
    """#

    static let bootstrap = #"""
    (function (info) {
      "use strict";
      var global = typeof globalThis !== "undefined" ? globalThis : window;
      if (Object.prototype.hasOwnProperty.call(global, "nib")) return;
      var handlers = global.webkit && global.webkit.messageHandlers;
      var channel = handlers ? handlers[info.handler] : null;
      if (!channel || typeof channel.postMessage !== "function") return;
      var postNative = channel.postMessage.bind(channel);

      var pluginId = String(info.id);
      var principal = "plugin:" + pluginId;
      var CODES = ["invalid_params", "not_found", "permission_denied", "user_denied", "locked", "conflict",
                   "invariant_violation", "timeout", "unavailable", "unsupported", "internal"];
      var pageConsole = global.console;
      var consoleError = pageConsole && typeof pageConsole.error === "function" ? pageConsole.error.bind(pageConsole) : null;

      // ------------------------------------------------------------------------------------------------------------
      // Values and errors (as prelude.js)

      function format(value) {
        if (typeof value === "string") return value;
        if (value === undefined) return "undefined";
        if (typeof value === "function") return "[Function" + (value.name ? " " + value.name : "") + "]";
        if (value instanceof Error) return (value.name || "Error") + ": " + value.message;
        try {
          var json = JSON.stringify(value, null, 2);
          return json === undefined ? String(value) : json;
        } catch (e) {
          return String(value);
        }
      }

      function nibError(code, message, hint, path) {
        var err = new Error(message);
        err.name = "NibError";
        err.code = CODES.indexOf(code) >= 0 ? code : "internal";
        if (typeof path === "string") err.path = path;
        if (typeof hint === "string") err.hint = hint;
        return err;
      }

      function errorFromJSON(json) {
        var e;
        try { e = JSON.parse(json); } catch (_) { e = { code: "internal", message: String(json) }; }
        if (!e || typeof e !== "object") e = { code: "internal", message: String(e) };
        return nibError(e.code, e.message === undefined ? "unknown error" : String(e.message), e.hint, e.path);
      }

      function report(level, text) {
        try { postNative({ method: "log", args: JSON.stringify({ level: level, text: String(text) }) }); } catch (_) {}
      }

      function logError(where, e) {
        var text = where + ": " + (e && e.message !== undefined ? String(e.message) : format(e));
        if (consoleError) { try { consoleError(text); } catch (_) {} }
        report("error", text);
      }

      // ------------------------------------------------------------------------------------------------------------
      // The native bridge

      function callNative(method, args) {
        var payload;
        try { payload = JSON.stringify(args === undefined ? null : args); } catch (e) {
          return Promise.reject(nibError("invalid_params", "the arguments are not JSON: " + e.message));
        }
        if (payload === undefined) payload = "null";
        var sent;
        try { sent = postNative({ method: String(method), args: payload }); } catch (e) {
          return Promise.reject(nibError("unavailable", "the panel is not connected to Nib"));
        }
        return Promise.resolve(sent).then(function (json) {
          return json === undefined || json === null || json === "" ? undefined : JSON.parse(json);
        }, function (e) {
          throw errorFromJSON(e && e.message !== undefined ? e.message : String(e));
        });
      }

      function fire(method, args) {
        callNative(method, args).catch(function (e) { logError("nib " + method, e); });
      }

      function exec(command, params, opts) {
        var args = { command: String(command), params: params === undefined || params === null ? {} : params };
        if (opts && opts.dryRun) args.dryRun = true;
        if (opts && typeof opts.group === "string" && opts.group) args.group = opts.group;
        return callNative("execute", args);
      }

      function field(name) {
        return function (value) {
          return value && typeof value === "object" && !Array.isArray(value) && value[name] !== undefined ? value[name] : value;
        };
      }

      function list(value) {
        if (Array.isArray(value)) return value;
        if (value && typeof value === "object") {
          var keys = ["results", "hits", "items", "commands"];
          for (var i = 0; i < keys.length; i++) if (Array.isArray(value[keys[i]])) return value[keys[i]];
        }
        return value;
      }

      function assign(target, source) {
        if (source && typeof source === "object") {
          for (var k in source) if (Object.prototype.hasOwnProperty.call(source, k)) target[k] = source[k];
        }
        return target;
      }

      // One ctx per event delivery: calls through it share the delivery's undo group (one Undo step).
      function makeContext(c) {
        c = c || {};
        return Object.freeze({
          group: String(c.group || ""),
          principal: principal,
          readOnly: !!c.readOnly,
          execute: function (command, params, opts) {
            var args = { command: String(command), params: params === undefined || params === null ? {} : params };
            if (c.group) args.group = String(c.group);
            if (opts && opts.dryRun) args.dryRun = true;
            return callNative("execute", args);
          }
        });
      }

      var currentSettings = Object.freeze(info.settings && typeof info.settings === "object" ? info.settings : {});
      function applySettings(settings) {
        if (settings && typeof settings === "object") currentSettings = Object.freeze(settings);
      }

      // ------------------------------------------------------------------------------------------------------------
      // nib.*

      var plugin = {};
      Object.defineProperty(plugin, "id", { value: pluginId, enumerable: true });
      Object.defineProperty(plugin, "version", { value: String(info.version || ""), enumerable: true });
      Object.defineProperty(plugin, "settings", { get: function () { return currentSettings; }, enumerable: true });

      var panelInfo = info.panel && typeof info.panel === "object" ? info.panel : {};
      var panel = Object.freeze({
        id: String(panelInfo.id || ""),
        params: Object.freeze(panelInfo.params && typeof panelInfo.params === "object" ? panelInfo.params : {})
      });

      var commands = Object.freeze({
        execute: function (command, params, opts) { return exec(command, params, opts); },
        batch: function (calls, opts) {
          var stop = opts && opts.stopOnError !== undefined ? !!opts.stopOnError : true;
          return exec("commands.batch", { calls: calls || [], stopOnError: stop }).then(list);
        },
        register: function (id) {
          throw nibError("unsupported", "an HTML panel cannot register the command handler '" + String(id) + "'",
                         "register handlers in the plugin's entry script (main.js) and run them with nib.commands.execute");
        },
        list: function (namespace) { return exec("commands.list", namespace ? { namespace: String(namespace) } : {}).then(list); },
        describe: function (id) { return exec("commands.describe", { id: String(id) }); }
      });

      var query = Object.freeze({
        context: function () { return exec("query.context", {}); },
        tree: function (root, depth) {
          var p = {};
          if (root !== undefined && root !== null) p.root = root;
          if (depth !== undefined && depth !== null) p.depth = depth;
          return exec("query.tree", p);
        },
        get: function (ref, opts) { return exec("query.get", assign(assign({}, opts), { ref: ref })); },
        find: function (filter) { return exec("query.find", assign({}, filter)); },
        search: function (text, scope) {
          var p = { query: String(text) };
          if (scope) p.scope = scope;
          return exec("search.text", p).then(list);
        },
        pageText: function (page) { return exec("recognize.pageText", { page: page }); },
        render: function (page, opts) { return exec("render.page", assign(assign({}, opts), { page: page })); }
      });

      var decorations = new Set();
      var decorationSeq = 0;
      var canvas = Object.freeze({
        decorate: function (page, display, opts) {
          var id = opts && typeof opts.id === "string" && opts.id ? opts.id : pluginId + ".panel.decoration." + (++decorationSeq);
          var ttl = opts && typeof opts.ttl === "number" ? opts.ttl : 5;
          return exec("canvas.decorate", { page: page, id: id, display: display, ttl: ttl }).then(function () {
            decorations.add(id);
            return id;
          });
        },
        clear: function (id) {
          var ids = id ? [String(id)] : Array.from(decorations);
          return Promise.all(ids.map(function (d) {
            decorations.delete(d);
            return exec("canvas.clearDecorations", { id: d });
          })).then(function () { return undefined; });
        }
      });

      var listeners = new Map();
      var events = Object.freeze({
        on: function (type, fn, filter) {
          if (typeof type !== "string" || !type) throw nibError("invalid_params", "events.on needs an event type such as 'tx.committed'");
          if (typeof fn !== "function") throw nibError("invalid_params", "events.on needs a callback function");
          var entry = { fn: fn, self: !!(filter && filter.self), doc: filter && filter.doc ? String(filter.doc).replace(/^doc:/, "") : null };
          var set = listeners.get(type);
          if (!set) { set = new Set(); listeners.set(type, set); }
          set.add(entry);
          fire("events.subscribe", { type: type, self: entry.self, delta: 1 });
          var active = true;
          return function unsubscribe() {
            if (!active) return;
            active = false;
            set.delete(entry);
            if (set.size === 0) listeners.delete(type);
            fire("events.subscribe", { type: type, self: entry.self, delta: -1 });
          };
        }
      });

      var ui = Object.freeze({
        toast: function (message) { fire("ui.toast", { message: format(message) }); },
        confirm: function (title, message) {
          return callNative("ui.confirm", { title: format(title), message: message === undefined ? null : format(message) });
        },
        prompt: function (title, placeholder, initial) {
          return callNative("ui.prompt", {
            title: format(title),
            placeholder: placeholder === undefined || placeholder === null ? null : String(placeholder),
            initial: initial === undefined || initial === null ? null : String(initial)
          });
        },
        choose: function (title, options) {
          return callNative("ui.choose", { title: format(title), options: (options || []).map(format) });
        },
        openPanel: function (id) { return callNative("ui.openPanel", { id: String(id) }).then(function () { return undefined; }); },
        postToPanel: function (id, message) {
          fire("ui.postToPanel", { id: String(id), message: message === undefined ? null : message });
        }
      });

      var storage = Object.freeze({
        get: function (key) {
          return callNative("storage.get", { key: String(key) }).then(function (r) { return r && r.found ? r.value : undefined; });
        },
        set: function (key, value) {
          var args = { key: String(key) };
          if (value !== undefined) args.value = value;
          return callNative("storage.set", args).then(function () { return undefined; });
        },
        remove: function (key) { return callNative("storage.remove", { key: String(key) }).then(function () { return undefined; }); },
        keys: function () { return callNative("storage.keys", {}); }
      });

      var settings = Object.freeze({
        get: function (name) {
          return callNative("settings.get", { name: String(name) }).then(function (v) { return v === null ? undefined : v; });
        },
        set: function (name, value) {
          return callNative("settings.set", { name: String(name), value: value === undefined ? null : value })
            .then(function () { return undefined; });
        }
      });

      function utf8Base64(text) {
        var bytes = new TextEncoder().encode(String(text));
        var binary = "";
        for (var i = 0; i < bytes.length; i += 0x8000) {
          binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
        }
        return btoa(binary);
      }

      var assets = Object.freeze({
        put: function (doc, data, ext) {
          var p = { doc: doc, ext: String(ext) };
          if (data && data.base64 !== undefined) p.base64 = String(data.base64);
          else if (data && data.url !== undefined) p.url = String(data.url);
          else if (data && data.text !== undefined) p.base64 = utf8Base64(data.text);
          else return Promise.reject(nibError("invalid_params", "nib.assets.put needs {base64}, {url} or {text}"));
          return exec("asset.put", p).then(field("asset"));
        },
        upload: function (data, ext) {
          var base64;
          if (data && data.base64 !== undefined) base64 = String(data.base64);
          else if (data && data.text !== undefined) base64 = utf8Base64(data.text);
          else return Promise.reject(nibError("invalid_params", "nib.assets.upload needs {base64} or {text}"));
          return exec("asset.upload", { base64: base64, ext: String(ext) }).then(field("url"));
        },
        url: function (doc, asset) { return exec("asset.get", { doc: doc, asset: String(asset) }).then(field("url")); }
      });

      var ai = Object.freeze({
        complete: function (request) { return callNative("ai.complete", request || {}); }
      });

      var net = Object.freeze({
        fetch: function (url, init) { return callNative("net.fetch", { url: String(url), init: init || {} }); }
      });

      // Panel <-> main.js messaging. Messages that arrive before the page's first nib.onMessage wait for it.
      var messageListeners = new Set();
      var pendingMessages = [];
      function deliverMessage(message) {
        if (messageListeners.size === 0) {
          if (pendingMessages.length >= 64) pendingMessages.shift();
          pendingMessages.push(message);
          return;
        }
        Array.from(messageListeners).forEach(function (fn) {
          try { fn(message); } catch (err) { logError("nib.onMessage", err); }
        });
      }
      function onMessage(fn) {
        if (typeof fn !== "function") throw nibError("invalid_params", "nib.onMessage needs a callback function");
        messageListeners.add(fn);
        if (pendingMessages.length) {
          var queued = pendingMessages.splice(0, pendingMessages.length);
          Promise.resolve().then(function () { queued.forEach(deliverMessage); });
        }
        return function () { messageListeners.delete(fn); };
      }
      function postMessage(message) {
        return callNative("panel.postMessage", { message: message === undefined ? null : message }).then(function () { return undefined; });
      }

      var nib = Object.freeze({
        plugin: Object.freeze(plugin), panel: panel, commands: commands, query: query, canvas: canvas, events: events,
        ui: ui, storage: storage, settings: settings, assets: assets, ai: ai, net: net,
        onMessage: onMessage, postMessage: postMessage
      });

      // ------------------------------------------------------------------------------------------------------------
      // Nib's tokens as CSS variables (layered, so the plugin's own CSS wins)

      var tokenSheet = null;
      var tokenStyle = null;
      function applyTokens(css) {
        if (typeof document === "undefined" || typeof css !== "string") return;
        // The plugin draws inside Nib's droplet and never its own glass: backdrop filters are off in every layer.
        var text = "@layer nib {\n" + css + "\n*, *::before, *::after { -webkit-backdrop-filter: none !important; " +
                   "backdrop-filter: none !important; }\n}\n";
        try {
          if (!tokenSheet) {
            tokenSheet = new CSSStyleSheet();
            document.adoptedStyleSheets = [tokenSheet].concat(Array.prototype.slice.call(document.adoptedStyleSheets || []));
          }
          tokenSheet.replaceSync(text);
          return;
        } catch (_) {
          tokenSheet = null;
        }
        var install = function () {
          if (!tokenStyle) {
            tokenStyle = document.createElement("style");
            tokenStyle.setAttribute("data-nib", "tokens");
          }
          tokenStyle.textContent = text;
          var head = document.head || document.documentElement;
          if (head && tokenStyle.parentNode !== head) head.insertBefore(tokenStyle, head.firstChild);
        };
        if (document.head || document.documentElement) install();
        else document.addEventListener("DOMContentLoaded", install, { once: true });
      }
      applyTokens(info.tokens);
      if (typeof document !== "undefined" && document.addEventListener) {
        document.addEventListener("DOMContentLoaded", function () {
          // A page that replaced document.adoptedStyleSheets keeps Nib's tokens underneath its own sheets.
          if (tokenSheet && Array.prototype.indexOf.call(document.adoptedStyleSheets || [], tokenSheet) < 0) {
            document.adoptedStyleSheets = [tokenSheet].concat(Array.prototype.slice.call(document.adoptedStyleSheets || []));
          }
        });
      }

      // ------------------------------------------------------------------------------------------------------------
      // Entries from Nib

      function deliverEvent(value) {
        if (!value || !value.event) return;
        var e = value.event;
        var set = listeners.get(e.type);
        if (!set) return;
        var own = e.principal === principal;
        var ctx = makeContext(value.ctx);
        Array.from(set).forEach(function (l) {
          if (own && !l.self) return;
          if (l.doc && l.doc !== e.doc) return;
          try {
            var r = l.fn(e, ctx);
            if (r && typeof r.then === "function") r.then(null, function (err) { logError("event " + e.type, err); });
          } catch (err) {
            logError("event " + e.type, err);
          }
        });
      }

      function receive(kind, json) {
        var value;
        try { value = json === undefined || json === null || json === "" ? null : JSON.parse(json); } catch (_) { return; }
        if (kind === "message") deliverMessage(value);
        else if (kind === "event") deliverEvent(value);
        else if (kind === "settings") applySettings(value);
        else if (kind === "tokens") applyTokens(value);
      }

      if (pageConsole) {
        ["warn", "error"].forEach(function (level) {
          var original = pageConsole[level];
          if (typeof original !== "function") return;
          pageConsole[level] = function () {
            var parts = [];
            for (var i = 0; i < arguments.length; i++) parts.push(format(arguments[i]));
            report(level, parts.join(" "));
            return original.apply(pageConsole, arguments);
          };
        });
      }
      if (typeof global.addEventListener === "function") {
        global.addEventListener("error", function (ev) {
          report("error", (ev && ev.message ? ev.message : "script error") +
                 (ev && ev.filename ? " (" + ev.filename + ":" + ev.lineno + ")" : ""));
        });
        global.addEventListener("unhandledrejection", function (ev) {
          var r = ev ? ev.reason : undefined;
          report("error", "unhandled rejection: " + (r && r.message !== undefined ? r.message : format(r)));
        });
      }

      Object.defineProperty(global, info.host, {
        value: Object.freeze({ receive: receive }), writable: false, configurable: false, enumerable: false
      });
      Object.defineProperty(global, "nib", { value: nib, writable: false, configurable: false, enumerable: false });
      fire("hello", { url: global.location ? String(global.location.href) : "" });
    })
    """#
}

// MARK: - Routing calls from the panel

/// Dialogs and toasts a panel asks for (`nib.ui.*` and the page's own alert/confirm/prompt). Tests install a fake.
@MainActor
protocol PanelDialogPresenting: AnyObject {
    @discardableResult
    func toast(_ message: String) -> Bool
    func confirm(_ title: String, message: String?) async throws -> Bool
    func prompt(_ title: String, placeholder: String?, initial: String?) async throws -> String?
    func choose(_ title: String, options: [String]) async throws -> Int?
    func alert(_ message: String) async
}

/// Which event types the page listens to (`nib.events.on`), counted like the runtime does: every listener wants
/// other principals' events; only `{self: true}` listeners want the plugin's own.
struct PanelSubscriptions: Equatable {
    private var all: [String: Int] = [:]
    private var own: [String: Int] = [:]

    mutating func change(_ type: String, includeOwn: Bool, delta: Int) {
        all[type] = max(0, (all[type] ?? 0) + delta)
        if all[type] == 0 { all[type] = nil }
        if includeOwn {
            own[type] = max(0, (own[type] ?? 0) + delta)
            if own[type] == 0 { own[type] = nil }
        }
    }

    func wants(_ type: String, own isOwn: Bool) -> Bool {
        isOwn ? (own[type] ?? 0) > 0 : (all[type] ?? 0) > 0
    }

    var isEmpty: Bool { all.isEmpty }

    mutating func reset() {
        all = [:]
        own = [:]
    }
}

/// At most one delivery per (type, document, own) every `interval` (100 ms, as the runtime): a burst collapses into
/// the first event now and the latest one when the interval ends.
struct PanelEventThrottle {
    struct Key: Hashable {
        var type: String
        var doc: String?
        var own: Bool
    }

    enum Decision: Equatable {
        /// Deliver now.
        case send
        /// Keep it; flush `key` after this many seconds.
        case schedule(TimeInterval)
        /// Replaced the event already waiting for a flush.
        case merged
    }

    let interval: TimeInterval
    private var lastSent: [Key: TimeInterval] = [:]
    private var pending: [Key: JSONValue] = [:]

    init(interval: TimeInterval = 0.1) {
        self.interval = interval
    }

    mutating func offer(_ event: JSONValue, key: Key, now: TimeInterval) -> Decision {
        if pending[key] != nil {
            pending[key] = event
            return .merged
        }
        if let last = lastSent[key], now - last < interval {
            pending[key] = event
            return .schedule(interval - (now - last))
        }
        lastSent[key] = now
        return .send
    }

    /// The event waiting for `key`, if any; it counts as sent now.
    mutating func flush(_ key: Key, now: TimeInterval) -> JSONValue? {
        guard let event = pending.removeValue(forKey: key) else { return nil }
        lastSent[key] = now
        return event
    }

    mutating func reset() {
        lastSent = [:]
        pending = [:]
    }
}

/// At most `limit` dialogs within `window` seconds. A page that asks for more (an alert or confirm in a loop would
/// otherwise stack window-modal alerts until the app is force-quit) gets every further dialog of that document
/// answered at once. The recent times carry over to the next document, so reloading itself earns a page nothing.
struct PanelDialogLimiter: Equatable {
    let limit: Int
    let window: TimeInterval
    private var shown: [TimeInterval] = []
    private(set) var blocked = false

    init(limit: Int = 3, window: TimeInterval = 10) {
        self.limit = limit
        self.window = window
    }

    mutating func allow(now: TimeInterval) -> Bool {
        if blocked { return false }
        shown = shown.filter { now - $0 < window }
        if shown.count >= limit {
            blocked = true
            return false
        }
        shown.append(now)
        return true
    }

    /// A new document: the block ends, the recent dialogs still count.
    mutating func newDocument() {
        blocked = false
    }

    mutating func reset() {
        shown = []
        blocked = false
    }
}

/// `nib.storage` has one owner, the plugin runtime (F077), which merges per key across devices. A panel reaches it
/// through `PluginRuntimeHandle.evaluate`: a fixed expression over the plugin's own `nib.storage` whose only inputs
/// are JSON literals, answering `{ok, value}` or `{ok: false, error}` as text.
enum PanelStorageScript {
    static let methods: Set<String> = ["storage.get", "storage.set", "storage.remove", "storage.keys"]

    static func expression(_ method: String, _ args: JSONValue) throws -> String {
        guard methods.contains(method) else { throw NibError(.notFound, "unknown plugin API '\(method)'") }
        let key = args["key"]?.stringValue ?? ""
        if method != "storage.keys" && key.isEmpty {
            throw NibError.invalid("storage needs a key", path: "$.key")
        }
        let k = JSONValue.string(key).jsonString()
        let call: String
        switch method {
        case "storage.get":
            call = "nib.storage.get(\(k)).then(function (v) { return { found: v !== undefined, value: v === undefined ? null : v }; })"
        case "storage.set":
            if let value = args["value"] {
                call = "nib.storage.set(\(k), \(value.jsonString())).then(function () { return null; })"
            } else {
                call = "nib.storage.remove(\(k)).then(function () { return null; })"
            }
        case "storage.remove":
            call = "nib.storage.remove(\(k)).then(function () { return null; })"
        default:
            call = "nib.storage.keys()"
        }
        return "Promise.resolve().then(function () { return " + call + "; }).then(function (v) { "
            + "return JSON.stringify({ ok: true, value: v === undefined ? null : v }); }, function (e) { "
            + "return JSON.stringify({ ok: false, error: { code: e && e.code ? String(e.code) : \"internal\", "
            + "message: e && e.message !== undefined ? String(e.message) : String(e), "
            + "hint: e && typeof e.hint === \"string\" ? e.hint : null } }); })"
    }

    /// The value, or the storage error, from what `evaluate` returned. The runtime reports its own failures (not
    /// running, hung) as "Error [code]: message".
    static func decode(_ text: String) throws -> JSONValue {
        if let v = try? JSONValue.parse(text), let ok = v["ok"]?.boolValue {
            if ok { return v["value"] ?? .null }
            let e = v["error"]
            let code = e?["code"]?.stringValue.flatMap { NibError.Code(rawValue: $0) } ?? .internalError
            throw NibError(code, e?["message"]?.stringValue ?? "plugin storage failed", hint: e?["hint"]?.stringValue)
        }
        if text.hasPrefix("Error ["), let close = text.firstIndex(of: "]") {
            let rawCode = String(text[text.index(text.startIndex, offsetBy: 7)..<close])
            var message = String(text[text.index(after: close)...])
            if message.hasPrefix(":") { message.removeFirst() }
            throw NibError(NibError.Code(rawValue: rawCode) ?? .internalError,
                           message.trimmingCharacters(in: .whitespaces))
        }
        throw NibError(.internalError, "plugin storage answered unexpectedly: " + String(text.prefix(200)))
    }
}

/// Routes one panel's calls. Everything that touches documents, the library or the app runs through the command bus
/// as `plugin:<id>` (so the plugin's grants, locked documents and confirmations apply exactly as for main.js); UI
/// asks, own settings, storage, AI and network follow the runtime's rules.
@MainActor
final class PanelBridge {
    let manifest: PluginManifest
    let panelID: String
    let params: JSONValue
    private weak var app: NibApp?
    /// The window the panel shows in (session defaults for `query.context`, `panel.open`).
    var session: () -> EditorSession?
    let dialogs: PanelDialogPresenting
    /// Pushes into the page: (kind, payload).
    var send: ((String, JSONValue) -> Void)?
    /// The injected script ran in a new document (first load or reload): the page can now receive pushes.
    var onHello: (() -> Void)?
    /// Seconds for the event throttle (tests replace it).
    var clock: () -> TimeInterval = { Date().timeIntervalSince1970 }
    private(set) var subscriptions = PanelSubscriptions()
    private var throttle = PanelEventThrottle()
    private var dialogLimiter = PanelDialogLimiter()
    private let log = Logger(subsystem: "app.nib", category: "pluginpanels")

    var principal: Principal { .plugin(manifest.id) }

    init(app: NibApp, manifest: PluginManifest, panelID: String, params: JSONValue,
         session: @escaping () -> EditorSession?, dialogs: PanelDialogPresenting) {
        self.app = app
        self.manifest = manifest
        self.panelID = panelID
        self.params = params
        self.session = session
        self.dialogs = dialogs
    }

    // MARK: Boot

    /// The `info` the injected script starts from.
    func bootInfo(tokens: String?) -> JSONValue {
        [
            "id": .string(manifest.id), "version": .string(manifest.version), "name": .string(manifest.name),
            "principal": .string(principal.description), "handler": .string(PanelBridgeScript.handlerName),
            "host": .string(PanelBridgeScript.hostObject),
            "panel": ["id": .string(panelID), "params": params],
            "settings": currentSettings(), "tokens": tokens.map { JSONValue.string($0) } ?? .null,
        ]
    }

    /// Current values of `contributes.settings` (declared defaults where unset), as `nib.plugin.settings`.
    func currentSettings() -> JSONValue {
        guard let app = app else { return [:] }
        var out: [String: JSONValue] = [:]
        for (key, schema) in manifest.contributes?.settings?["properties"]?.objectValue ?? [:] {
            out[key] = app.settings.json("plugin.\(manifest.id).\(key)") ?? schema["default"] ?? .null
        }
        return .object(out)
    }

    /// A new document started in the panel: its listeners are gone. The dialog budget carries over (a page that
    /// reloads itself does not earn new dialogs); only the block on the old document ends.
    func resetPage() {
        subscriptions.reset()
        throttle.reset()
        dialogLimiter.newDocument()
    }

    /// The user reloaded the panel: dialogs start afresh.
    func resetDialogBudget() {
        dialogLimiter.reset()
    }

    /// Whether the page may show one more dialog (its own alert/confirm/prompt or a `nib.ui` dialog). False once it
    /// asked too often: further dialogs are answered at once (cancelled) for the rest of the document.
    func allowDialog() -> Bool {
        dialogLimiter.allow(now: clock())
    }

    // MARK: Calls

    /// Calls answered at once (no awaiting): hello and bookkeeping, fire-and-forget posts. nil = not one of them.
    func handleNow(_ method: String, _ args: JSONValue) throws -> JSONValue? {
        switch method {
        case "hello":
            resetPage()
            onHello?()
            return .null
        case "log":
            // The page's own text often quotes note content: it stays private in the system log (only the ids are
            // public), as diagnostics.export promises no note content.
            let level = args["level"]?.stringValue ?? "log"
            let text = args["text"]?.stringValue ?? ""
            if level == "error" {
                log.error("\(self.manifest.id, privacy: .public) panel \(self.panelID, privacy: .public): \(text, privacy: .private)")
            } else {
                log.notice("\(self.manifest.id, privacy: .public) panel \(self.panelID, privacy: .public): \(text, privacy: .private)")
            }
            return .null
        case "events.subscribe":
            guard let type = args["type"]?.stringValue, !type.isEmpty else {
                throw NibError.invalid("missing event type", path: "$.type")
            }
            let delta = (args["delta"]?.doubleValue ?? 1) < 0 ? -1 : 1
            subscriptions.change(type, includeOwn: args["self"]?.boolValue ?? false, delta: delta)
            return .null
        case "ui.toast":
            let message = args["message"]?.stringValue ?? ""
            if !dialogs.toast(message) {
                log.notice("\(self.manifest.id, privacy: .public) toast with no window: \(message, privacy: .private)")
            }
            return .null
        case "ui.postToPanel":
            return try postToPanel(args)
        case "panel.postMessage":
            return try postToMain(args)
        default:
            return nil
        }
    }

    /// Every call, awaited.
    func handle(_ method: String, _ args: JSONValue) async throws -> JSONValue {
        if let immediate = try handleNow(method, args) { return immediate }
        switch method {
        case "execute": return try await execute(args)
        case "ui.confirm", "ui.prompt", "ui.choose": return try await dialog(method, args)
        case "ui.openPanel": return try await openPanel(args)
        case "settings.get": return try await settingsGet(args)
        case "settings.set": return try await settingsSet(args)
        case "ai.complete": return try await aiComplete(args)
        case "net.fetch": return try await fetch(args)
        default:
            if PanelStorageScript.methods.contains(method) { return try await storage(method, args) }
            throw NibError(.notFound, "unknown plugin API '\(method)'", hint: "see plugin.docs for the nib.* API")
        }
    }

    /// `{code, message, path?, hint?}` as text, for the reply handler's error string.
    static func errorText(_ error: NibError) -> String {
        (error.json["error"] ?? ["code": "internal", "message": .string(error.message)]).jsonString()
    }

    // MARK: Commands

    private func requireApp() throws -> NibApp {
        guard let app = app else { throw NibError.unavailable("the app") }
        return app
    }

    private func execute(_ args: JSONValue) async throws -> JSONValue {
        let app = try requireApp()
        guard let command = args["command"]?.stringValue, !command.isEmpty else {
            throw NibError.invalid("missing command id", path: "$.command")
        }
        var group: String?
        if let g = args["group"]?.stringValue, !g.isEmpty {
            guard g.count <= 64, g.range(of: "^[A-Za-z0-9_:.-]+$", options: .regularExpression) != nil else {
                throw NibError.invalid("an undo group is 1 to 64 of [A-Za-z0-9_:.-]", path: "$.group")
            }
            group = g
        }
        let inv = Invocation(command: command, params: args["params"] ?? [:], principal: principal, session: session(),
                             group: group, dryRun: args["dryRun"]?.boolValue ?? false)
        return try await app.bus.execute(inv).value
    }

    // MARK: UI

    private func dialog(_ method: String, _ args: JSONValue) async throws -> JSONValue {
        // Too many dialogs from this document: answer as if cancelled (confirm false, prompt and choose null).
        guard allowDialog() else { return method == "ui.confirm" ? false : .null }
        let title = args["title"]?.stringValue ?? manifest.name
        switch method {
        case "ui.confirm":
            return .bool(try await dialogs.confirm(title, message: args["message"]?.stringValue))
        case "ui.prompt":
            let text = try await dialogs.prompt(title, placeholder: args["placeholder"]?.stringValue,
                                                initial: args["initial"]?.stringValue)
            return text.map { JSONValue.string($0) } ?? .null
        default:
            let options = (args["options"]?.arrayValue ?? []).compactMap { $0.stringValue }
            guard !options.isEmpty else { throw NibError.invalid("nib.ui.choose needs at least one option", path: "$.options") }
            let index = try await dialogs.choose(title, options: options)
            return index.map { JSONValue.number(Double($0)) } ?? .null
        }
    }

    /// One of this plugin's own panels (never another plugin's or a native one).
    private func ownPanel(_ args: JSONValue) throws -> String {
        guard let id = args["id"]?.stringValue, !id.isEmpty else { throw NibError.invalid("missing panel id", path: "$.id") }
        guard manifest.contributes?.panels?.contains(where: { $0.id == id }) == true else {
            throw NibError(.notFound, "'\(id)' is not one of this plugin's panels", path: "$.id",
                           hint: "declare it in manifest contributes.panels")
        }
        return id
    }

    /// Showing its own UI needs no permission: `panel.open` for exactly that id, as the window's user action.
    private func openPanel(_ args: JSONValue) async throws -> JSONValue {
        let app = try requireApp()
        let id = try ownPanel(args)
        do {
            _ = try await app.bus.execute(Invocation(command: CommandIDs.panelOpen, params: ["id": .string(id)],
                                                     principal: .user, session: session() ?? app.services.sessions.active))
        } catch let e as NibError where e.code == .notFound {
            throw NibError(.unavailable, "panels cannot be opened here: \(e.message)")
        }
        return .null
    }

    /// `nib.ui.postToPanel` from a panel: the same `plugin.message` event main.js would emit, so every open copy
    /// of the target panel (and one opened within the mailbox's lifetime) receives it.
    private func postToPanel(_ args: JSONValue) throws -> JSONValue {
        let app = try requireApp()
        let id = try ownPanel(args)
        app.events.emit(NibEventType.pluginMessage, principal: principal,
                        payload: ["panel": .string(id), "to": "panel", "message": args["message"] ?? .null])
        return .null
    }

    /// `nib.postMessage`: a `plugin.message` for main.js, through `PluginRuntimeHandle.postMessage`.
    private func postToMain(_ args: JSONValue) throws -> JSONValue {
        guard let handle = runtimeHandle() else {
            throw NibError(.unavailable, "the plugin \(manifest.name) is not running",
                           hint: "enable or reload the plugin in Settings › Plugins")
        }
        handle.postMessage(from: panelID, message: args["message"] ?? .null)
        return .null
    }

    private func runtimeHandle() -> PluginRuntimeHandle? {
        app?.services.get(ServiceKeys.pluginHost, as: PluginHosting.self)?.handle(manifest.id)
    }

    // MARK: Settings and storage

    private func settingsGet(_ args: JSONValue) async throws -> JSONValue {
        let app = try requireApp()
        guard let name = args["name"]?.stringValue, !name.isEmpty else {
            throw NibError.invalid("missing setting name", path: "$.name")
        }
        let own = "plugin.\(manifest.id)."
        if name.hasPrefix(own) {
            // A plugin always reads its own settings (as in main.js).
            let key = String(name.dropFirst(own.count))
            let fallback = manifest.contributes?.settings?["properties"]?[key]?["default"]
            return app.settings.json(name) ?? fallback ?? .null
        }
        let r = try await execute(["command": .string(CommandIDs.settingsGet), "params": ["name": .string(name)]])
        return r["value"] ?? .null
    }

    private func settingsSet(_ args: JSONValue) async throws -> JSONValue {
        guard let name = args["name"]?.stringValue, !name.isEmpty else {
            throw NibError.invalid("missing setting name", path: "$.name")
        }
        _ = try await execute(["command": .string(CommandIDs.settingsSet),
                               "params": ["name": .string(name), "value": args["value"] ?? .null]])
        return .null
    }

    private func storage(_ method: String, _ args: JSONValue) async throws -> JSONValue {
        let expression = try PanelStorageScript.expression(method, args)
        guard let handle = runtimeHandle() else {
            throw NibError(.unavailable, "plugin storage needs the plugin \(manifest.name) to be running",
                           hint: "enable or reload the plugin in Settings › Plugins")
        }
        return try PanelStorageScript.decode(await handle.evaluate(expression))
    }

    // MARK: AI and network

    /// Scopes with no command behind them: declared in the manifest AND granted.
    private func requireScope(_ scope: Scope) throws {
        let app = try requireApp()
        guard manifest.permissions.contains(scope.rawValue), app.gateway.grants(principal).contains(scope) else {
            throw NibError(.permissionDenied, "missing permission: \(scope.rawValue)",
                           hint: "declare \"\(scope.rawValue)\" in the manifest's permissions; the user must grant it")
        }
    }

    private func aiComplete(_ args: JSONValue) async throws -> JSONValue {
        try requireScope(.ai)
        guard let ai = app?.services.ai, ai.isConfigured else {
            throw NibError(.unavailable, "no AI provider is set up", hint: "the user can add one in Settings › AI")
        }
        guard let raw = args["messages"]?.arrayValue, !raw.isEmpty else {
            throw NibError.invalid("nib.ai.complete needs at least one message", path: "$.messages")
        }
        var messages: [AIMessage] = []
        for (i, m) in raw.enumerated() {
            let role = m["role"]?.stringValue ?? "user"
            guard role == "user" || role == "assistant" else {
                throw NibError.invalid("role is 'user' or 'assistant'", path: "$.messages[\(i)].role")
            }
            guard let text = m["text"]?.stringValue else { throw NibError.invalid("missing text", path: "$.messages[\(i)].text") }
            let images = (m["images"]?.arrayValue ?? []).compactMap { $0.stringValue }
                .map { AssetRef($0.hasPrefix("tmp:") ? String($0.dropFirst(4)) : $0) }
            messages.append(AIMessage(role: role, text: text, images: images.isEmpty ? nil : images))
        }
        let mode: AIMode = args["mode"]?.stringValue == AIMode.edit.rawValue ? .edit : .ask
        let tools: [String]? = args["tools"]?.arrayValue.map { $0.compactMap { $0.stringValue } }
        let steps = min(max(args["maxSteps"]?.intValue ?? 40, 1), 40)
        let request = AIRequest(system: args["system"]?.stringValue, messages: messages, tools: tools, mode: mode,
                                principal: principal, maxSteps: steps, jsonOutput: args["json"]?.boolValue ?? false)
        let response = try await ai.complete(request)
        var out: [String: JSONValue] = ["text": .string(response.text), "changes": try JSONValue.from(response.changes)]
        if let g = response.group { out["group"] = .string(g) }
        return .object(out)
    }

    private func fetch(_ args: JSONValue) async throws -> JSONValue {
        try requireScope(.network)
        guard let s = args["url"]?.stringValue, let url = URL(string: s) else {
            throw NibError.invalid("nib.net.fetch needs an https URL", path: "$.url")
        }
        let hosts = Set(PanelContentRules.normalizedHosts(manifest.network?.hosts ?? []))
        try PanelFetcher.check(url, hosts: hosts)
        let options = args["init"] ?? [:]
        let method = (options["method"]?.stringValue ?? "GET").uppercased()
        guard PanelFetcher.methods.contains(method) else {
            throw NibError.invalid("unsupported method \(method)", path: "$.init.method")
        }
        var headers: [String: String] = [:]
        for (k, v) in options["headers"]?.objectValue ?? [:] { headers[k] = v.stringValue ?? v.jsonString() }
        var body: Data?
        if let b64 = options["bodyBase64"]?.stringValue {
            guard let data = Data(base64Encoded: b64) else { throw NibError.invalid("bodyBase64 is not base64", path: "$.init.bodyBase64") }
            body = data
        } else if let text = options["body"]?.stringValue {
            body = Data(text.utf8)
        }
        return try await PanelFetcher(hosts: hosts).fetch(url, method: method, headers: headers, body: body)
    }

    // MARK: Events

    /// A bus event: delivered to the page when it listens for the type (own events only to `{self: true}`
    /// listeners), throttled per type and document. `plugin.message` never arrives here: that is `nib.onMessage`.
    func offer(_ event: NibEvent) {
        guard event.type != NibEventType.pluginMessage, !subscriptions.isEmpty else { return }
        let own = event.principal == principal
        guard subscriptions.wants(event.type, own: own), let json = try? JSONValue.from(event) else { return }
        let key = PanelEventThrottle.Key(type: event.type, doc: event.doc?.raw, own: own)
        switch throttle.offer(json, key: key, now: clock()) {
        case .send:
            deliver(json)
        case .merged:
            break
        case .schedule(let delay):
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
                guard let self = self else { return }
                if let e = self.throttle.flush(key, now: self.clock()) { self.deliver(e) }
            }
        }
    }

    private func deliver(_ event: JSONValue) {
        send?("event", ["event": event, "ctx": ["group": .string(NibID.make().raw), "readOnly": false]])
    }
}

// MARK: - nib.net.fetch

/// `nib.net.fetch` from a panel: https only, exactly the manifest's hosts (redirects included), no cookies or cache,
/// 30 s in all and 10 MB. The body is collected as it arrives and the request is cancelled as soon as the announced
/// length or the bytes received pass the cap, so the cap bounds Nib's own memory too (as F077's `PluginFetcher`: the
/// response is read in Nib's process, not the panel's web process). One instance per request.
final class PanelFetcher: NSObject, URLSessionDataDelegate {
    /// Prepended to the session's protocol classes (tests register a stub `URLProtocol`).
    static var protocolClasses: [AnyClass] = []
    static let methods: Set<String> = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]
    static let maxBytes = 10 * 1024 * 1024
    static let timeout: TimeInterval = 30

    let hosts: Set<String>
    let maxBytes: Int
    let timeout: TimeInterval

    // Guarded by `lock` (delegate callbacks arrive on the session's queue).
    private let lock = NSLock()
    private var received = Data()
    private var response: URLResponse?
    private var tooLarge = false
    private var continuation: CheckedContinuation<(Data, URLResponse?), Error>?

    init(hosts: Set<String>, maxBytes: Int = PanelFetcher.maxBytes, timeout: TimeInterval = PanelFetcher.timeout) {
        self.hosts = Set(hosts.map { $0.lowercased() })
        self.maxBytes = maxBytes
        self.timeout = timeout
    }

    /// Throws `permission_denied` unless `url` is https (no credentials) and its host is allowed.
    static func check(_ url: URL, hosts: Set<String>) throws {
        guard url.scheme?.lowercased() == "https" else {
            throw NibError(.permissionDenied, "nib.net.fetch only reaches https URLs", path: "$.url")
        }
        guard url.user == nil, url.password == nil else {
            throw NibError.invalid("URLs with credentials are not allowed", path: "$.url")
        }
        let host = (url.host ?? "").lowercased()
        guard !host.isEmpty, hosts.contains(host) else {
            throw NibError(.permissionDenied, "'\(host)' is not in the plugin's network.hosts", path: "$.url",
                           hint: "add the host to manifest network.hosts; the user consents to it on install")
        }
    }

    func fetch(_ url: URL, method: String, headers: [String: String], body: Data?) async throws -> JSONValue {
        try PanelFetcher.check(url, hosts: hosts)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = body
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        // The request timeout is an idle timeout; the resource timeout bounds the whole call.
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.protocolClasses = PanelFetcher.protocolClasses + (config.protocolClasses ?? [])
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let data: Data
        let response: URLResponse?
        do {
            (data, response) = try await load(request, in: session)
        } catch let e as NibError {
            throw e
        } catch let e as URLError where e.code == .timedOut {
            throw NibError(.timeout, "\(url.host ?? "the server") did not answer within \(Int(timeout)) s")
        } catch {
            throw NibError(.unavailable, "the request to \(url.host ?? "the server") failed: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw NibError(.unavailable, "\(url.host ?? "the server") did not answer over HTTP")
        }
        return PanelFetcher.result(http, data: data)
    }

    private func load(_ request: URLRequest, in session: URLSession) async throws -> (Data, URLResponse?) {
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse?), Error>) in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private var sizeLimitError: NibError {
        let limit = maxBytes >= 1_048_576 ? "\(maxBytes / 1_048_576) MB" : "\(maxBytes) bytes"
        return NibError(.unsupported, "the response is larger than \(limit)",
                        hint: "request less data (a range, a page, a smaller format)")
    }

    /// `{status, headers, text, base64?}`: text for UTF-8 bodies, else lossy text plus base64.
    static func result(_ http: HTTPURLResponse, data: Data) -> JSONValue {
        var headerOut: [String: JSONValue] = [:]
        for (k, v) in http.allHeaderFields {
            headerOut[String(describing: k).lowercased()] = .string(String(describing: v))
        }
        var out: [String: JSONValue] = ["status": .number(Double(http.statusCode)), "headers": .object(headerOut)]
        if let text = String(data: data, encoding: .utf8) {
            out["text"] = .string(text)
        } else {
            out["text"] = .string(String(decoding: data, as: UTF8.self))
            out["base64"] = .string(data.base64EncodedString())
        }
        return .object(out)
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let announcedTooLarge = response.expectedContentLength > Int64(maxBytes)
        lock.lock()
        self.response = response
        if announcedTooLarge { tooLarge = true }
        lock.unlock()
        completionHandler(announcedTooLarge ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        var cancel = tooLarge
        if !tooLarge {
            if received.count + data.count > maxBytes {
                tooLarge = true
                received = Data()
                cancel = true
            } else {
                received.append(data)
            }
        }
        lock.unlock()
        if cancel { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let result: Result<(Data, URLResponse?), Error>
        if tooLarge {
            result = .failure(sizeLimitError)
        } else if let error = error {
            result = .failure(error)
        } else {
            result = .success((received, response ?? task.response))
        }
        received = Data()
        lock.unlock()
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, (try? PanelFetcher.check(url, hosts: hosts)) != nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

// MARK: - Dialogs in the window

/// `nib.ui.*` dialogs and the page's own alert/confirm/prompt, as system alerts presented in the panel's window. Each
/// names the plugin, so a plugin cannot pass its dialog off as Nib's or the system's.
@MainActor
final class PanelDialogs: PanelDialogPresenting {
    private let pluginName: String
    private let navigator: () -> SceneNavigator?

    init(pluginName: String, navigator: @escaping () -> SceneNavigator?) {
        self.pluginName = pluginName
        self.navigator = navigator
    }

    private func window() throws -> SceneNavigator {
        guard !NibApp.isHostlessTest, let n = navigator() else {
            throw NibError(.unavailable, "there is no window to show the plugin's dialog in")
        }
        return n
    }

    @discardableResult
    func toast(_ message: String) -> Bool {
        guard !NibApp.isHostlessTest, let host = navigator()?.floatingHost else { return false }
        host.postToast(message)
        return true
    }

    func confirm(_ title: String, message: String?) async throws -> Bool {
        let n = try window()
        return await ask(n, cancelled: false) { finish in
            let alert = UIAlertController(title: title, message: self.source(message), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in finish(false) })
            alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { _ in finish(true) })
            return alert
        }
    }

    func prompt(_ title: String, placeholder: String?, initial: String?) async throws -> String? {
        let n = try window()
        return await ask(n, cancelled: nil) { finish in
            let alert = UIAlertController(title: title, message: self.source(nil), preferredStyle: .alert)
            alert.addTextField { field in
                field.placeholder = placeholder
                field.text = initial
            }
            alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in finish(nil) })
            alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { [weak alert] _ in
                finish(alert?.textFields?.first?.text ?? "")
            })
            return alert
        }
    }

    func choose(_ title: String, options: [String]) async throws -> Int? {
        let n = try window()
        return await ask(n, cancelled: nil) { finish in
            let alert = UIAlertController(title: title, message: self.source(nil), preferredStyle: .alert)
            for (index, option) in options.enumerated() {
                alert.addAction(UIAlertAction(title: option, style: .default) { _ in finish(index) })
            }
            alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in finish(nil) })
            return alert
        }
    }

    func alert(_ message: String) async {
        guard let n = try? window() else { return }
        await ask(n, cancelled: true) { (finish: @escaping (Bool) -> Void) in
            let alert = UIAlertController(title: self.pluginName, message: self.source(message), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { _ in finish(true) })
            return alert
        }
    }

    private func source(_ message: String?) -> String {
        let from = String(localized: "From the plugin \(pluginName)")
        guard let m = message, !m.isEmpty else { return from }
        return m + "\n\n" + from
    }

    /// Presents the alert `make` builds and waits for its one answer. If nothing could present it (another modal was
    /// up), it answers `cancelled` instead of waiting forever.
    @discardableResult
    private func ask<T>(_ navigator: SceneNavigator, cancelled: T,
                        make: (@escaping (T) -> Void) -> UIAlertController) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            var answered = false
            let finish: (T) -> Void = { value in
                guard !answered else { return }
                answered = true
                continuation.resume(returning: value)
            }
            let alert = make(finish)
            navigator.presentModal(alert)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if alert.presentingViewController == nil && alert.viewIfLoaded?.window == nil { finish(cancelled) }
            }
        }
    }
}
