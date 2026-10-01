# Nib collaboration relay

A self-hosted, dependency-free Node 20+ WebSocket server. It moves collaboration bytes between a host and guests;
Nib's collaboration session handles approval, permissions, snapshots, edits, undo and live cursors. A room supports
**50 simultaneous participants, including the host**. Larger groups use Nib's folder sync.

## Run

```sh
export RELAY_TOKEN="$(openssl rand -hex 32)"
node tools/relay/relay.mjs
```

Keep that token in your service manager's protected environment file so it survives restarts. The server refuses
missing tokens and tokens shorter than 16 characters. Defaults: `HOST=127.0.0.1`, `PORT=8787`, `RELAY_PATH=/`.
`GET /health` returns `ok`; it discloses no rooms or participants. Logs never contain tokens, codes or note bytes.

In Nib, open **Settings → Sync → Collaboration Relay**, enter `ws://` or `wss://` URL and the shared token, then save.
Tokens stay in the device-only Keychain, separately for each endpoint. A blank, untouched token field keeps the
existing token; “Clear saved token” removes it on Save. Changing the endpoint or clearing its URL disconnects the
current relay. An empty URL disables internet collaboration. Missing Keychain credentials after re-signing require
re-entry. Invite participants with Nib's join code and approve them in the collaboration panel.

The command `relay.configure {"url":"wss://notes.example.com/"}` changes only the URL and is sensitive: non-user
callers require confirmation. It accepts no token parameter. `settings.get {"name":"relay.url"}` reads the endpoint;
`settings.set` cannot bypass the configure command. The settings form submits tokens through a short-lived private
slot consumed by the user command handler, never through JSON parameters, command hooks, events or command results.

## Tailscale

Run the relay on your always-on machine and either:

* Bind only its Tailscale address: `HOST=100.x.y.z node tools/relay/relay.mjs`, then configure
  `ws://100.x.y.z:8787/` on devices in the same tailnet. Tailscale encrypts the private network link.
* Keep the default loopback listener and expose it using Tailscale Serve with HTTPS/WebSocket forwarding. Configure
  the resulting `wss://machine.tailnet-name.ts.net/` URL. Restrict access using your tailnet ACLs.

Do not bind to `0.0.0.0` and publish unencrypted WebSockets directly to the internet. Outside a trusted private link,
terminate TLS at a proxy or tunnel and use `wss://`. The relay operator can read the forwarded bytes: this transport
does not add end-to-end encryption. Host approval still controls access to the document.

## Cloudflare Tunnel

Keep Node bound to loopback. In your tunnel configuration, route a hostname to `http://127.0.0.1:8787`:

```yaml
ingress:
  - hostname: notes.example.com
    service: http://127.0.0.1:8787
  - service: http_status:404
```

Run your named tunnel with `cloudflared tunnel run <tunnel-name>` and configure `wss://notes.example.com/` in Nib.
WebSocket Upgrade and the Authorization header must reach Node. If you use another reverse proxy, preserve these
headers, disable buffering, and set its idle timeout above 60 seconds. Interactive Cloudflare Access login pages are
not supported by the native transport; restrict the tunnel appropriately and use the shared relay token.

## Wire protocol and limits

Every WebSocket message is UTF-8 JSON:

```json
{"type":"message","from":"peer-uuid","to":"target-uuid","data":"aGVsbG8="}
```

`to` is optional for broadcast. Host broadcasts may include `except: ["peer-id", ...]` (at most 50 ids)
to exclude the author without duplicating uplink frames; older relays may echo to that author, which F072 ignores. `data` is canonical base64, at most 64 KiB decoded; the entire text message is at most
96 KiB. Connect using `Authorization: Bearer <token>`. Tokens never travel in URLs. Browser Origin requests are
rejected; this endpoint is for native clients. Client frames must be masked, as required by
[RFC 6455](https://www.rfc-editor.org/rfc/rfc6455), and the server handles fragmentation, ping/pong and close frames.
Compression and binary WebSocket messages are not negotiated.

1. Send `host` or `join`, with `from` set to a random transport identity and `data` containing base64-encoded
   `{"code":"join-code","name":"display name","resume":"private-random-capability"}`. Codes are case sensitive.
2. Receive `welcome` from `relay` addressed to your identity. Its data is `{"peers":[{"id":"...","name":"..."}],"host":"host-id"}`.
3. `peers` carries the same roster whenever a connection joins, leaves or reconnects. It excludes the receiving
   client. On disconnect the host id can remain while that host is absent from `peers`.
4. `message` carries opaque collaboration bytes. Sender identity is checked against the registered connection.
   Guest traffic routes only to the host; the host sends to individual guests or broadcasts. Rooms are isolated.
5. `error` data is `{"code":"...","message":"..."}`. `full` indicates the 50-person cap and folder-sync fallback;
   other codes include `not_found`, `conflict`, `permission_denied`, `invalid_params`.

The resume capability is never published in rosters. It prevents another participant from claiming the host's
visible identity during reconnection. The host's room is retained for 120 seconds after disconnection; an absent
host cannot accept new guests. The returning host must present the same identity and capability. The server stores
only capability hashes. Guest identity reservations survive an abrupt disconnect for 120 seconds, and are released by an explicit
transport `bye`. Retained rooms and identities per room are each capped at 1000. Fragmented messages are limited
to 1024 fragments, including empty fragments; closing sockets are destroyed within one second.

Native connections reconnect with jittered exponential delays (1, 2, 4, 8, 16, then 30 seconds, capped), retaining
identity and capability. A welcome only resets the backoff after 30 seconds of stable connectivity. Leaving or configuring another URL cancels retries. Auth/framing failures require
reconfiguration. Both ends use heartbeat checks. Pending native sends are ordered and bounded to 8 MiB (including
the in-flight send); capacity exhaustion throws `NibError(.timeout, ..., hint: "relay-busy")` without accepting the
frame. Host fan-out uses one broadcast with exclusions when that is cheaper than individual targets. The server
pauses sender ingress and parsing at 1 MiB of a target's queued TCP output, resuming only once every congested
broadcast target drains. A target is disconnected if it fails to drain for 30 seconds or exceeds a 16 MiB hard cap. Unsatisfied document changes are reconciled by Nib's session
protocol after reconnection, rather than replaying stale transport messages. No document bytes are stored on disk.

## Verify

```sh
node tools/relay/relay.mjs --selftest
```

Starts a loopback server on an ephemeral port, connects raw WebSocket clients (works on Node 20), joins two peers,
relays a 64 KiB binary payload in base64, and asserts replies. It also checks authentication, fragmented frames,
interleaved ping, room isolation, prohibited guest routing, host link replacement (host-absent roster before return), an 8 MiB burst to a paused receiver, guest identity
reservations, fragment and room bounds, broadcast exclusions, and rejection of participant 51. It prints
`RELAY SELFTEST OK` and exits 0, or exits nonzero on failure. No external services or npm install are needed. The
repository CI invokes this command when the relay exists. Swift tests cover framing, configuration, credential
isolation, command conformance, ordered sends, host routing, reconnect backoff and leaving.

## Contract request: F072 send backpressure and integration coverage

F092 owns neither `NibContracts` nor `FeatCollab`. The contracts-v2 `CollabTransport.send` API is synchronous and
has no capacity await; F072's `deliver` and `streamBlob` currently treat any send error as a failed transfer.
The native 8 MiB queue remains bounded, so a snapshot/file larger than the queue can still fail with a slow uplink.
This requires a coordinated F072 change before large production transfers are reliable; raising the queue limit
would only move that failure and increase memory pressure.

Request to F072: make delivery asynchronous and retry only the first unaccepted frame on `relay-busy`, waiting
100–250 ms between attempts with a bounded deadline, stopping when the session closes or the route changes.
Advance the frame/blob cursor only after `send` accepts that frame. Apply the same logic to large content snapshots
and sync replies, including their header frames. Alternatively, the contracts owner can add
`waitForCapacity(bytes:) async throws` with a default no-op to `CollabTransport`, which F072 awaits between sends.
The relay's slow socket test verifies 20 MiB arrives in order when its caller honors the existing retry signal.
It does not establish F072 blob acceptance while F072 still lacks that retry loop.

Request to F072 tests: use a relay-like roster sequence (host absent, then present while guests stay connected),
rejoin using the stored admission secret, and assert the guest's next patch is applied to the host after digest sync.
Also cover a real 20 MiB snapshot/file on a slow transport and disabling the relay during host and guest sessions.
F092 tests exercise the underlying roster transition, ordered retry/drain, and bus-driven session retirement without
importing or modifying the F072-owned module/test target.

The F092 review branch restores the previously imported F072 files to `origin/main` to honor feature ownership.
On that base F072 is still scaffolded; its implementation must land through the F072 branch before the live
session integration requests above can be verified end to end.
