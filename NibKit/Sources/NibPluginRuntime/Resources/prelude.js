// Nib plugin prelude (F077). Builds the `nib.*` API of docs/PLUGIN_API.md inside one plugin's JSContext.
//
// The runtime evaluates this file once per plugin, before the plugin's entry bundle. Its value is a function that the
// runtime calls with (globalObject, natives, infoJSON); it installs `nib`, `console`, timers and the small web
// helpers, and returns the dispatch table the runtime uses to enter JavaScript (command handlers, events, timers,
// the developer console).
//
// Every API call crosses ONE native bridge, as JSON strings:
//   __nib_call(method, argsJSON, callId, resolve, reject)  ->  resolve(resultJSON) | reject(errorJSON)
// `callId` is the token of the entry context (a command handler or an event callback) that a `ctx.execute` belongs
// to, or "" for calls made outside a ctx. The native side hops to the main actor and runs the command bus as
// principal "plugin:<id>" (nib.storage goes to the plugin's storage queue instead). The other natives are
// synchronous and never enter the bus: __nib_log, __nib_done, __nib_timer, __nib_subscribe. They arrive on the
// `natives` object, not as globals, so plugin code cannot reach them.
(function (global, natives, infoJSON) {
  "use strict";

  const info = JSON.parse(infoJSON);
  const pluginId = info.id;
  const principal = "plugin:" + pluginId;
  const nativeCall = natives.__nib_call;
  const nativeLog = natives.__nib_log;
  const nativeDone = natives.__nib_done;
  const nativeTimer = natives.__nib_timer;
  const nativeSubscribe = natives.__nib_subscribe;
  const CODES = ["invalid_params", "not_found", "permission_denied", "user_denied", "locked", "conflict",
                 "invariant_violation", "timeout", "unavailable", "unsupported", "internal"];

  // ---------------------------------------------------------------------------------------------------------------
  // Values and errors

  function format(value) {
    if (typeof value === "string") return value;
    if (value === undefined) return "undefined";
    if (typeof value === "function") return "[Function" + (value.name ? " " + value.name : "") + "]";
    if (value instanceof Error) return (value.name || "Error") + ": " + value.message;
    try {
      const json = JSON.stringify(value, null, 2);
      return json === undefined ? String(value) : json;
    } catch (e) {
      return String(value);
    }
  }

  function nibError(code, message, hint, path) {
    const err = new Error(message);
    err.name = "NibError";
    err.code = CODES.indexOf(code) >= 0 ? code : "internal";
    if (typeof path === "string") err.path = path;
    if (typeof hint === "string") err.hint = hint;
    return err;
  }

  function errorFromJSON(json) {
    let e;
    try { e = JSON.parse(json); } catch (_) { e = { code: "internal", message: String(json) }; }
    if (!e || typeof e !== "object") e = { code: "internal", message: String(e) };
    return nibError(e.code, e.message === undefined ? "unknown error" : String(e.message), e.hint, e.path);
  }

  // What a thrown value becomes on the native side: {code, message, path?, hint?, stack?}.
  function errorToJSON(e) {
    if (e && typeof e === "object") {
      const known = typeof e.code === "string" && CODES.indexOf(e.code) >= 0;
      let message = e.message !== undefined ? String(e.message) : format(e);
      if (!known && e instanceof Error && e.name && e.name !== "Error" && e.name !== "NibError") {
        message = e.name + ": " + message;
      }
      const out = { code: known ? e.code : "internal", message: message };
      if (typeof e.path === "string") out.path = e.path;
      if (typeof e.hint === "string") out.hint = e.hint;
      if (typeof e.stack === "string" && e.stack) out.stack = e.stack;
      return out;
    }
    return { code: "internal", message: format(e) };
  }

  function log(level, args) {
    const parts = [];
    for (let i = 0; i < args.length; i++) parts.push(format(args[i]));
    nativeLog(level, parts.join(" "));
  }

  function logError(where, e) {
    const j = errorToJSON(e);
    nativeLog("error", where + ": " + j.message + (j.stack ? "\n" + j.stack : ""));
  }

  // ---------------------------------------------------------------------------------------------------------------
  // The native bridge

  function callNative(method, args, token) {
    return new Promise(function (resolve, reject) {
      nativeCall(method, JSON.stringify(args === undefined ? null : args), token || "",
        function (json) {
          try { resolve(json === undefined || json === "" ? undefined : JSON.parse(json)); } catch (e) { reject(e); }
        },
        function (json) { reject(errorFromJSON(json)); });
    });
  }

  function exec(command, params, opts) {
    const args = { command: String(command), params: params === undefined || params === null ? {} : params };
    if (opts && opts.dryRun) args.dryRun = true;
    if (opts && typeof opts.group === "string" && opts.group) args.group = opts.group;
    return callNative("execute", args, "");
  }

  function field(name) {
    return function (value) {
      return value && typeof value === "object" && !Array.isArray(value) && value[name] !== undefined ? value[name] : value;
    };
  }

  function list(value) {
    if (Array.isArray(value)) return value;
    if (value && typeof value === "object") {
      const keys = ["results", "hits", "items", "commands"];
      for (let i = 0; i < keys.length; i++) if (Array.isArray(value[keys[i]])) return value[keys[i]];
    }
    return value;
  }

  function assign(target, source) {
    if (source && typeof source === "object") for (const k in source) if (Object.prototype.hasOwnProperty.call(source, k)) target[k] = source[k];
    return target;
  }

  // One ctx per entry into JavaScript. Calls through it share the entry's undo group, read-only mode and
  // confirmation policy (the native side builds the Invocation from the handler's CommandContext).
  function makeContext(c) {
    return Object.freeze({
      group: c.group,
      principal: principal,
      readOnly: !!c.readOnly,
      execute: function (command, params, opts) {
        const args = { command: String(command), params: params === undefined || params === null ? {} : params };
        if (opts && opts.dryRun) args.dryRun = true;
        return callNative("execute", args, c.token);
      }
    });
  }

  let currentSettings = Object.freeze(info.settings || {});
  function applySettings(settings) {
    if (settings && typeof settings === "object") currentSettings = Object.freeze(settings);
  }

  // ---------------------------------------------------------------------------------------------------------------
  // nib.*

  const plugin = {};
  Object.defineProperty(plugin, "id", { value: pluginId, enumerable: true });
  Object.defineProperty(plugin, "version", { value: String(info.version || ""), enumerable: true });
  Object.defineProperty(plugin, "settings", { get: function () { return currentSettings; }, enumerable: true });

  const handlers = new Map();
  const commands = Object.freeze({
    execute: function (command, params, opts) { return exec(command, params, opts); },
    batch: function (calls, opts) {
      const stop = opts && opts.stopOnError !== undefined ? !!opts.stopOnError : true;
      return exec("commands.batch", { calls: calls || [], stopOnError: stop }).then(list);
    },
    register: function (id, handler) {
      if (typeof id !== "string" || id.indexOf(pluginId + ".") !== 0) {
        throw nibError("invalid_params", "command ids must start with '" + pluginId + ".'", "declare the command in manifest contributes.commands");
      }
      if (typeof handler !== "function") throw nibError("invalid_params", "the handler of '" + id + "' must be a function");
      if (handlers.has(id)) nativeLog("warn", "handler for '" + id + "' registered again; the new one replaces it");
      handlers.set(id, handler);
      nativeLog("nib", "registered " + id);
    },
    list: function (namespace) { return exec("commands.list", namespace ? { namespace: String(namespace) } : {}).then(list); },
    describe: function (id) { return exec("commands.describe", { id: String(id) }); }
  });

  const query = Object.freeze({
    context: function () { return exec("query.context", {}); },
    tree: function (root, depth) {
      const p = {};
      if (root !== undefined && root !== null) p.root = root;
      if (depth !== undefined && depth !== null) p.depth = depth;
      return exec("query.tree", p);
    },
    get: function (ref, opts) { return exec("query.get", assign(assign({}, opts), { ref: ref })); },
    find: function (filter) { return exec("query.find", assign({}, filter)); },
    search: function (text, scope) {
      const p = { query: String(text) };
      if (scope) p.scope = scope;
      return exec("search.text", p).then(list);
    },
    pageText: function (page) { return exec("recognize.pageText", { page: page }); },
    render: function (page, opts) { return exec("render.page", assign(assign({}, opts), { page: page })); }
  });

  const decorations = new Set();
  let decorationSeq = 0;
  const canvas = Object.freeze({
    decorate: function (page, display, opts) {
      const id = opts && typeof opts.id === "string" && opts.id ? opts.id : pluginId + ".decoration." + (++decorationSeq);
      const ttl = opts && typeof opts.ttl === "number" ? opts.ttl : 5;
      return exec("canvas.decorate", { page: page, id: id, display: display, ttl: ttl }).then(function () {
        decorations.add(id);
        return id;
      });
    },
    clear: function (id) {
      // Without an id, clear only this plugin's own decorations (canvas.clearDecorations {} would clear everyone's).
      const ids = id ? [String(id)] : Array.from(decorations);
      return Promise.all(ids.map(function (d) {
        decorations.delete(d);
        return exec("canvas.clearDecorations", { id: d });
      })).then(function () { return undefined; });
    }
  });

  const listeners = new Map();
  const events = Object.freeze({
    on: function (type, fn, filter) {
      if (typeof type !== "string" || !type) throw nibError("invalid_params", "events.on needs an event type such as 'tx.committed'");
      if (typeof fn !== "function") throw nibError("invalid_params", "events.on needs a callback function");
      const entry = { fn: fn, self: !!(filter && filter.self), doc: filter && filter.doc ? String(filter.doc).replace(/^doc:/, "") : null };
      let set = listeners.get(type);
      if (!set) { set = new Set(); listeners.set(type, set); }
      set.add(entry);
      nativeSubscribe(type, entry.self, 1);
      let active = true;
      return function unsubscribe() {
        if (!active) return;
        active = false;
        set.delete(entry);
        if (set.size === 0) listeners.delete(type);
        nativeSubscribe(type, entry.self, -1);
      };
    }
  });

  const ui = Object.freeze({
    toast: function (message) {
      callNative("ui.toast", { message: format(message) }, "").catch(function (e) { logError("nib.ui.toast", e); });
    },
    confirm: function (title, message) {
      return callNative("ui.confirm", { title: format(title), message: message === undefined ? null : format(message) }, "");
    },
    prompt: function (title, placeholder, initial) {
      return callNative("ui.prompt", {
        title: format(title),
        placeholder: placeholder === undefined || placeholder === null ? null : String(placeholder),
        initial: initial === undefined || initial === null ? null : String(initial)
      }, "");
    },
    choose: function (title, options) {
      return callNative("ui.choose", { title: format(title), options: (options || []).map(format) }, "");
    },
    openPanel: function (id) { return callNative("ui.openPanel", { id: String(id) }, "").then(function () { return undefined; }); },
    postToPanel: function (id, message) {
      callNative("ui.postToPanel", { id: String(id), message: message === undefined ? null : message }, "")
        .catch(function (e) { logError("nib.ui.postToPanel", e); });
    }
  });

  const storage = Object.freeze({
    get: function (key) {
      return callNative("storage.get", { key: String(key) }, "").then(function (r) { return r && r.found ? r.value : undefined; });
    },
    set: function (key, value) {
      const args = { key: String(key) };
      if (value !== undefined) args.value = value;
      return callNative("storage.set", args, "").then(function () { return undefined; });
    },
    remove: function (key) { return callNative("storage.remove", { key: String(key) }, "").then(function () { return undefined; }); },
    keys: function () { return callNative("storage.keys", {}, ""); }
  });

  const settings = Object.freeze({
    get: function (name) {
      return callNative("settings.get", { name: String(name) }, "").then(function (v) { return v === null ? undefined : v; });
    },
    set: function (name, value) {
      return callNative("settings.set", { name: String(name), value: value === undefined ? null : value }, "")
        .then(function () { return undefined; });
    }
  });

  function utf8Base64(text) {
    const bytes = encodeUTF8(String(text));
    let binary = "";
    for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
    return btoa(binary);
  }

  const assets = Object.freeze({
    put: function (doc, data, ext) {
      const p = { doc: doc, ext: String(ext) };
      if (data && data.base64 !== undefined) p.base64 = String(data.base64);
      else if (data && data.url !== undefined) p.url = String(data.url);
      else if (data && data.text !== undefined) p.base64 = utf8Base64(data.text);
      else return Promise.reject(nibError("invalid_params", "nib.assets.put needs {base64}, {url} or {text}"));
      return exec("asset.put", p).then(field("asset"));
    },
    upload: function (data, ext) {
      let base64;
      if (data && data.base64 !== undefined) base64 = String(data.base64);
      else if (data && data.text !== undefined) base64 = utf8Base64(data.text);
      else return Promise.reject(nibError("invalid_params", "nib.assets.upload needs {base64} or {text}"));
      return exec("asset.upload", { base64: base64, ext: String(ext) }).then(field("url"));
    },
    url: function (doc, asset) { return exec("asset.get", { doc: doc, asset: String(asset) }).then(field("url")); }
  });

  const ai = Object.freeze({
    complete: function (request) { return callNative("ai.complete", request || {}, ""); }
  });

  const net = Object.freeze({
    fetch: function (url, init) { return callNative("net.fetch", { url: String(url), init: init || {} }, ""); }
  });

  const nib = Object.freeze({
    plugin: Object.freeze(plugin), commands: commands, query: query, canvas: canvas, events: events, ui: ui,
    storage: storage, settings: settings, assets: assets, ai: ai, net: net
  });
  Object.defineProperty(global, "nib", { value: nib, writable: false, configurable: false, enumerable: false });

  // ---------------------------------------------------------------------------------------------------------------
  // Globals: console, timers, structuredClone, TextEncoder/TextDecoder, atob/btoa

  const consoleObject = Object.freeze({
    log: function () { log("log", arguments); },
    info: function () { log("info", arguments); },
    debug: function () { log("debug", arguments); },
    warn: function () { log("warn", arguments); },
    error: function () { log("error", arguments); }
  });
  Object.defineProperty(global, "console", { value: consoleObject, writable: true, configurable: true });

  const timers = new Map();
  let timerSeq = 0;
  function addTimer(fn, ms, args, repeat) {
    if (typeof fn !== "function") throw new TypeError("timer callbacks must be functions");
    const id = ++timerSeq;
    const delay = Math.max(0, Number(ms) || 0);
    if (!nativeTimer("set", id, delay, repeat)) throw new RangeError("too many timers are running in this plugin");
    timers.set(id, { fn: fn, args: args, repeat: repeat });
    return id;
  }
  function clearTimer(id) {
    const n = Number(id);
    if (timers.delete(n)) nativeTimer("clear", n, 0, false);
  }
  global.setTimeout = function (fn, ms) { return addTimer(fn, ms, Array.prototype.slice.call(arguments, 2), false); };
  global.setInterval = function (fn, ms) { return addTimer(fn, ms, Array.prototype.slice.call(arguments, 2), true); };
  global.clearTimeout = clearTimer;
  global.clearInterval = clearTimer;

  global.structuredClone = function (value) {
    return value === undefined ? undefined : JSON.parse(JSON.stringify(value));
  };

  function encodeUTF8(text) {
    const out = [];
    for (let i = 0; i < text.length; i++) {
      let c = text.charCodeAt(i);
      if (c >= 0xD800 && c <= 0xDBFF && i + 1 < text.length) {
        const d = text.charCodeAt(i + 1);
        if (d >= 0xDC00 && d <= 0xDFFF) { c = 0x10000 + ((c - 0xD800) << 10) + (d - 0xDC00); i++; }
      }
      if (c >= 0xD800 && c <= 0xDFFF) c = 0xFFFD;
      if (c < 0x80) out.push(c);
      else if (c < 0x800) out.push(0xC0 | (c >> 6), 0x80 | (c & 63));
      else if (c < 0x10000) out.push(0xE0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
      else out.push(0xF0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    }
    return new Uint8Array(out);
  }

  function decodeUTF8(bytes) {
    let out = "";
    let i = 0;
    while (i < bytes.length) {
      const b = bytes[i];
      let c = 0xFFFD, n = 1;
      if (b < 0x80) { c = b; }
      else if (b >= 0xC2 && b < 0xE0 && i + 1 < bytes.length && (bytes[i + 1] & 0xC0) === 0x80) {
        c = ((b & 31) << 6) | (bytes[i + 1] & 63); n = 2;
      } else if (b >= 0xE0 && b < 0xF0 && i + 2 < bytes.length && (bytes[i + 1] & 0xC0) === 0x80 && (bytes[i + 2] & 0xC0) === 0x80) {
        c = ((b & 15) << 12) | ((bytes[i + 1] & 63) << 6) | (bytes[i + 2] & 63); n = 3;
        if (c < 0x800 || (c >= 0xD800 && c <= 0xDFFF)) c = 0xFFFD;
      } else if (b >= 0xF0 && b < 0xF5 && i + 3 < bytes.length && (bytes[i + 1] & 0xC0) === 0x80 &&
                 (bytes[i + 2] & 0xC0) === 0x80 && (bytes[i + 3] & 0xC0) === 0x80) {
        c = ((b & 7) << 18) | ((bytes[i + 1] & 63) << 12) | ((bytes[i + 2] & 63) << 6) | (bytes[i + 3] & 63); n = 4;
        if (c < 0x10000 || c > 0x10FFFF) c = 0xFFFD;
      }
      if (c > 0xFFFF) { c -= 0x10000; out += String.fromCharCode(0xD800 + (c >> 10), 0xDC00 + (c & 1023)); }
      else out += String.fromCharCode(c);
      i += n;
    }
    return out;
  }

  global.TextEncoder = function TextEncoder() {};
  global.TextEncoder.prototype.encoding = "utf-8";
  global.TextEncoder.prototype.encode = function (text) { return encodeUTF8(text === undefined ? "" : String(text)); };
  global.TextDecoder = function TextDecoder(label) {
    const l = label === undefined ? "utf-8" : String(label).toLowerCase();
    if (l !== "utf-8" && l !== "utf8") throw new RangeError("only utf-8 is supported");
  };
  global.TextDecoder.prototype.encoding = "utf-8";
  global.TextDecoder.prototype.decode = function (input) {
    if (input === undefined) return "";
    if (input instanceof ArrayBuffer) return decodeUTF8(new Uint8Array(input));
    if (ArrayBuffer.isView(input)) return decodeUTF8(new Uint8Array(input.buffer, input.byteOffset, input.byteLength));
    throw new TypeError("TextDecoder.decode takes an ArrayBuffer or a typed array");
  };

  const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  global.btoa = function (input) {
    const s = String(input);
    let out = "";
    for (let i = 0; i < s.length; i += 3) {
      const a = s.charCodeAt(i), b = s.charCodeAt(i + 1), c = s.charCodeAt(i + 2);
      if (a > 255 || b > 255 || c > 255) throw new Error("btoa: the string contains characters outside Latin-1");
      const n = (a << 16) | ((b || 0) << 8) | (c || 0);
      out += B64[(n >> 18) & 63] + B64[(n >> 12) & 63] +
        (i + 1 < s.length ? B64[(n >> 6) & 63] : "=") + (i + 2 < s.length ? B64[n & 63] : "=");
    }
    return out;
  };
  global.atob = function (input) {
    const s = String(input).replace(/[\t\n\f\r ]/g, "").replace(/=+$/, "");
    if (s.length % 4 === 1 || /[^A-Za-z0-9+/]/.test(s)) throw new Error("atob: the string is not valid base64");
    let out = "";
    let buffer = 0, bits = 0;
    for (let i = 0; i < s.length; i++) {
      buffer = (buffer << 6) | B64.indexOf(s[i]);
      bits += 6;
      if (bits >= 8) { bits -= 8; out += String.fromCharCode((buffer >> bits) & 255); }
    }
    return out;
  };

  // ---------------------------------------------------------------------------------------------------------------
  // Entries from the runtime (called on the plugin's queue)

  function report(token, ok, value) {
    let json;
    if (ok) {
      try { json = JSON.stringify(value === undefined ? null : value); } catch (e) {
        ok = false;
        json = JSON.stringify({ code: "invalid_params", message: "the handler returned a value that is not JSON: " + e.message });
      }
      if (json === undefined) json = "null";
    } else {
      json = JSON.stringify(errorToJSON(value));
    }
    nativeDone(token, ok, json);
  }

  function settle(token, result) {
    Promise.resolve(result).then(function (v) { report(token, true, v); }, function (e) { report(token, false, e); });
  }

  // A command handler: params and ctx; its (awaited) return value is the command's result.
  function invoke(token, id, paramsJSON, ctxJSON) {
    const c = JSON.parse(ctxJSON);
    applySettings(c.settings);
    const handler = handlers.get(id);
    if (!handler) {
      report(token, false, nibError("not_found", "plugin " + pluginId + " has no handler for '" + id + "'",
                                    "call nib.commands.register('" + id + "', handler) in the plugin's entry script"));
      return;
    }
    let result;
    try {
      result = handler(paramsJSON ? JSON.parse(paramsJSON) : {}, makeContext(c));
    } catch (e) {
      report(token, false, e);
      return;
    }
    settle(token, result);
  }

  // One (possibly coalesced) event for every matching listener; done once every returned promise settled.
  function event(token, eventJSON, ctxJSON) {
    const e = JSON.parse(eventJSON);
    const c = JSON.parse(ctxJSON);
    applySettings(c.settings);
    const set = listeners.get(e.type);
    const own = e.principal === principal;
    const ctx = makeContext(c);
    const pending = [];
    if (set) {
      Array.from(set).forEach(function (l) {
        if (own && !l.self) return;
        if (l.doc && l.doc !== e.doc) return;
        try {
          const r = l.fn(e, ctx);
          if (r && typeof r.then === "function") pending.push(Promise.resolve(r).then(null, function (err) { logError("event " + e.type, err); }));
        } catch (err) {
          logError("event " + e.type, err);
        }
      });
    }
    Promise.all(pending).then(function () { report(token, true, null); });
  }

  function fire(id) {
    const t = timers.get(id);
    if (!t) return;
    if (!t.repeat) timers.delete(id);
    try { t.fn.apply(undefined, t.args); } catch (e) { logError("timer", e); }
  }

  // Developer console: evaluate in the global scope; promises are awaited; the result is formatted as text.
  function evaluate(token, source) {
    let result;
    try {
      result = (0, eval)(source);
    } catch (e) {
      report(token, false, e);
      return;
    }
    Promise.resolve(result).then(function (v) { report(token, true, format(v)); }, function (e) { report(token, false, e); });
  }

  return Object.freeze({ invoke: invoke, event: event, fire: fire, evaluate: evaluate });
})
