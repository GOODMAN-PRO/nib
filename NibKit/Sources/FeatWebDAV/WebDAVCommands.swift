import Foundation
import NibContracts

// MARK: - Settings

/// Device-local WebDAV settings. They are read-only for `settings.set` (every caller) and change only through
/// `webdav.configure`, which is `sensitive` (always confirmed for AI, plugins and the bridge), so a plain settings
/// write can never point the library at another server.
enum WebDAVSettings {
    static let url = SettingKey("webdav.url", default: "")
    static let user = SettingKey("webdav.user", default: "")
    static let folder = SettingKey("webdav.folder", default: "Nib")
    static let allowUntrustedCertificates = SettingKey("webdav.allowUntrustedCertificates", default: false)

    static func declare(_ s: SettingsStore, owner: String) {
        s.declare(url, summary: "WebDAV server address ('' = not set up). Change it with webdav.configure.", owner: owner,
                  schema: .str(), readOnly: true)
        s.declare(user, summary: "WebDAV user name. Change it with webdav.configure.", owner: owner, schema: .str(),
                  readOnly: true)
        s.declare(folder, summary: "Library folder on the WebDAV server. Change it with webdav.configure.", owner: owner,
                  schema: .str(), readOnly: true)
        s.declare(allowUntrustedCertificates, summary: "Accept a self-signed certificate from the WebDAV server.",
                  owner: owner, schema: .bool(), readOnly: true)
    }

    struct Values: Equatable {
        var url: String
        var user: String
        var folder: String
        var allowUntrustedCertificates: Bool
    }

    static func read(_ s: SettingsStore) -> Values {
        Values(url: s.get(url), user: s.get(user), folder: s.get(folder),
               allowUntrustedCertificates: s.get(allowUntrustedCertificates))
    }

    static func write(_ s: SettingsStore, _ v: Values) {
        s.set(url, v.url)
        s.set(user, v.user)
        s.set(folder, v.folder)
        s.set(allowUntrustedCertificates, v.allowUntrustedCertificates)
    }
}

// MARK: - Credentials

/// The WebDAV password, one Keychain entry per server and user (device-only, never synced). It is entered in
/// Settings › WebDAV and is never a command parameter, so it never passes through command hooks, plugins or the AI.
/// After a re-signed install the Keychain entry is gone and the status reads "credentials missing — re-enter".
enum WebDAVCredentials {
    static let service = "app.nib.webdav"

    static func account(url: String, user: String) -> String { user + "@" + url }

    static func password(url: String, user: String) -> String? {
        guard !url.isEmpty else { return nil }
        let value = Keychain.getString(service: service, account: account(url: url, user: user))
        return (value ?? "").isEmpty ? nil : value
    }

    /// Stores (or, with nil or "", removes) the password for a server and user.
    @discardableResult
    static func setPassword(_ password: String?, url: String, user: String) -> Bool {
        guard !url.isEmpty else { return false }
        let value = (password ?? "").isEmpty ? nil : password
        return Keychain.setString(value, service: service, account: account(url: url, user: user))
    }
}

// MARK: - Results

/// `webdav.status` (and the settings page).
struct WebDAVStatusInfo: Codable, Equatable {
    var configured: Bool
    var url: String?
    var user: String?
    var folder: String?
    var allowUntrustedCertificates: Bool
    /// A user name is set but its password is not in the Keychain (e.g. after re-signing): re-enter it.
    var credentialsMissing: Bool
    /// "unconfigured" | "idle" | "syncing" | "ok" | "warning" | "error"
    var state: String
    var running: Bool
    /// Unix seconds of the last sync that finished without a fatal error.
    var lastSync: Double?
    /// Files still to copy in the run in flight, else files the last run left for the next one.
    var pending: Int
    var errors: [String]
    var message: String?
    var lastResult: WebDAVSyncReport?
    /// Only with `check: true`.
    var connection: WebDAVConnectionCheck?
}

struct WebDAVConnectionCheck: Codable, Equatable {
    var ok: Bool
    var folderExists: Bool?
    var message: String
    var reason: String?
}

// MARK: - Commands

/// `webdav.syncNow {}`: one mirror pass now (joins a queued pass when one is already running).
struct WebDAVSyncNowCommand: NibCommand {
    struct Params: Codable {}
    typealias Output = WebDAVSyncReport

    static let descriptor = CommandDescriptor(
        id: "webdav.syncNow", title: String(localized: "Sync with WebDAV Now"),
        summary: "Mirror the library folder with the WebDAV server now (copies new and changed files both ways, keeps both on a divergence) → counts and errors.",
        params: .empty, examples: [[:]], effect: .session)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> WebDAVSyncReport {
        let engine = try WebDAVSyncEngine.resolve(ctx.services)
        _ = try engine.configuration()
        if ctx.dryRun {
            let now = Date().timeIntervalSince1970
            var preview = WebDAVSyncReport(started: now)
            preview.finished = now
            return preview
        }
        let report = await engine.sync(.manual)
        if let reason = report.failure, !report.cancelled {
            let error = engine.lastFailure ?? WebDAVError.local(report.errors.last ?? reason)
            throw error.nibError
        }
        return report
    }
}

/// `webdav.configure {url, user, folder, allowUntrustedCertificates?}`: sets up (or, with an empty url,
/// disconnects) WebDAV sync. The password is entered in Settings › WebDAV only.
struct WebDAVConfigureCommand: NibCommand {
    struct Params: Codable {
        var url: String
        var user: String
        var folder: String
        var allowUntrustedCertificates: Bool?
    }

    struct Output: Codable, Equatable {
        var configured: Bool
        var url: String
        var user: String
        var folder: String
        var allowUntrustedCertificates: Bool
        var credentialsMissing: Bool
    }

    static let descriptor = CommandDescriptor(
        id: "webdav.configure", title: String(localized: "Configure WebDAV"),
        summary: "Set up WebDAV sync: server url, user and the library folder on the server ('' url disconnects). The user enters the password in Settings › WebDAV.",
        params: .obj([
            "url": .str("server address, e.g. https://dav.example.com/remote.php/dav/files/alex/ ('' = disconnect)"),
            "user": .str("user name ('' = no authentication)"),
            "folder": .str("library folder on the server, e.g. Nib"),
            "allowUntrustedCertificates": .bool("accept a self-signed certificate from this server (default false)")
        ], required: ["url", "user", "folder"]),
        examples: [["url": "https://dav.example.com/remote.php/dav/files/alex/", "user": "alex", "folder": "Nib"]],
        effect: .session, sensitive: true)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let engine = try WebDAVSyncEngine.resolve(ctx.services)
        let settings = ctx.services.settings
        let old = WebDAVSettings.read(settings)
        if p.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let cleared = WebDAVSettings.Values(url: "", user: "", folder: WebDAVSettings.folder.defaultValue,
                                                allowUntrustedCertificates: false)
            if !ctx.dryRun {
                WebDAVCredentials.setPassword(nil, url: old.url, user: old.user)
                WebDAVSettings.write(settings, cleared)
                engine.configurationChanged()
            }
            return Output(configured: false, url: "", user: "", folder: cleared.folder, allowUntrustedCertificates: false,
                          credentialsMissing: false)
        }
        let server = try WebDAVConfiguration.normalizeServerURL(p.url).absoluteString
        let folder = try WebDAVConfiguration.normalizeFolder(p.folder)
        let user = p.user.trimmingCharacters(in: .whitespacesAndNewlines)
        let values = WebDAVSettings.Values(url: server, user: user, folder: folder,
                                           allowUntrustedCertificates: p.allowUntrustedCertificates ?? false)
        if !ctx.dryRun {
            // A password belongs to one server and user: a new server never inherits the old one's password.
            if !old.url.isEmpty, old.url != server || old.user != user {
                WebDAVCredentials.setPassword(nil, url: old.url, user: old.user)
            }
            WebDAVSettings.write(settings, values)
            engine.configurationChanged()
        }
        let missing = !user.isEmpty && WebDAVCredentials.password(url: server, user: user) == nil
        return Output(configured: true, url: server, user: user, folder: folder,
                      allowUntrustedCertificates: values.allowUntrustedCertificates, credentialsMissing: missing)
    }
}

/// `webdav.put {path, file}`: uploads one file (auto backup, F068) to a path relative to the server address.
/// Paths inside the mirrored library folder are refused, because the next sync would copy them into the library.
struct WebDAVPutCommand: NibCommand {
    struct Params: Codable {
        var path: String
        var file: String
    }

    struct Output: Codable, Equatable {
        var path: String
        var url: String
        var size: Int64
        var etag: String?
    }

    static let descriptor = CommandDescriptor(
        id: "webdav.put", title: String(localized: "Upload to WebDAV"),
        summary: "Upload one file to the WebDAV server at path (relative to the server address, outside the library folder); file is a tmp: ref or https URL. Used by auto backup.",
        params: .obj([
            "path": .str("destination path relative to the server address, e.g. Nib Backups/Physics.zip"),
            "file": .str("the file: a tmp: ref (asset.upload, export) or an https URL")
        ], required: ["path", "file"]),
        examples: [["path": "Nib Backups/Kinematics.zip", "file": "tmp:backup.zip"]],
        effect: .session)

    /// Validates `path`: relative, no "." or "..", not inside the library folder.
    static func components(_ path: String, libraryFolder: [String]) throws -> [String] {
        let parts = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { throw NibError(.invalidParams, "path is empty", path: "$.path") }
        if parts.contains(where: { $0 == "." || $0 == ".." }) {
            throw NibError(.invalidParams, "'.' and '..' are not allowed in path", path: "$.path")
        }
        if !libraryFolder.isEmpty, parts.count >= libraryFolder.count,
           WebDAVPaths.sameComponents(parts.prefix(libraryFolder.count), libraryFolder[...]) {
            throw NibError(.invalidParams, "path is inside the synced library folder '\(libraryFolder.joined(separator: "/"))'",
                           path: "$.path", hint: "upload backups to another folder, e.g. \"Nib Backups/…\"")
        }
        return parts
    }

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> Output {
        let engine = try WebDAVSyncEngine.resolve(ctx.services)
        let config = try engine.configuration()
        let parts = try components(p.path, libraryFolder: config.folderComponents)
        let target = WebDAVPaths.fileURL(config.serverURL, path: parts.joined(separator: "/"))
        if ctx.dryRun {
            return Output(path: parts.joined(separator: "/"), url: target.absoluteString, size: 0, etag: nil)
        }
        let file = try await ctx.inputFile(p.file)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw NibError(.invalidParams, "file must be a single file", path: "$.file",
                           hint: "zip folders first (backup.manual) and pass the tmp: ref")
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value ?? 0
        let etag = try await engine.put(file, components: parts, configuration: config)
        return Output(path: parts.joined(separator: "/"), url: target.absoluteString, size: size, etag: etag)
    }
}

/// `webdav.status {check?}`: configuration, last sync, pending files and errors; `check: true` also tests the
/// connection to the server and the library folder (the settings page's Test Connection).
struct WebDAVStatusCommand: NibCommand {
    struct Params: Codable {
        var check: Bool?
    }

    typealias Output = WebDAVStatusInfo

    static let descriptor = CommandDescriptor(
        id: "webdav.status", title: String(localized: "WebDAV Status"),
        summary: "WebDAV sync status: server, last sync, pending files, errors, 'credentials missing'; check: true also tests the connection.",
        params: .obj(["check": .bool("also test the connection to the server (network request)")]),
        examples: [[:], ["check": true]], effect: .read, target: .app)

    static func run(_ p: Params, _ ctx: CommandContext) async throws -> WebDAVStatusInfo {
        let engine = try WebDAVSyncEngine.resolve(ctx.services)
        return await engine.status(check: p.check ?? false)
    }
}
