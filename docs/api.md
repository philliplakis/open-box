# OpenBox Local API

OpenBox can keep Apple containers alive and expose their lifecycle over an
authenticated REST and WebSocket API.

## Start the Server

```bash
openbox serve
```

Defaults are `127.0.0.1:7070`, foreground execution, a 15-minute box TTL, four
CPUs, and 4 GiB per box. The server creates a 256-bit token on first launch and
stores it with mode `0600` under `~/Library/Application Support/OpenBox`.

```bash
openbox token show
openbox token rotate
```

Stop the server before rotating its token, then restart it so the in-memory
authentication value and token file stay in sync.

Every `/v1` request requires:

```text
Authorization: Bearer <token>
```

`GET /healthz` is unauthenticated and returns only status and version.

> OpenBox v0.2 serves plaintext HTTP. Bearer tokens, commands, terminal bytes,
> and output are not encrypted. Bind beyond loopback only on a trusted LAN. Do
> not expose the server to the internet.

## Workspace Grants

Host paths are registered only through the local CLI:

```bash
openbox workspace add ~/src/project --name project
openbox workspace list
openbox workspace remove ws-…
```

The API lists grant metadata with `GET /v1/workspaces`. Remote callers can use a
registered ID but cannot register a path or place arbitrary host paths in a box
request. Only one active box can use a registered workspace.

## REST API

Create an ephemeral box:

```bash
curl -sS http://127.0.0.1:7070/v1/boxes \
  -H "Authorization: Bearer $OPENBOX_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"workspace":{"type":"ephemeral"},"ttl_seconds":900}'
```

Create one from a registered workspace:

```json
{
  "workspace": {"type": "registered", "workspace_id": "ws-…"},
  "image": "docker.io/library/alpine:latest",
  "ttl_seconds": 900,
  "cpus": 4,
  "memory_mb": 4096
}
```

Routes:

- `GET /v1/workspaces`
- `POST /v1/boxes`
- `GET /v1/boxes`
- `GET /v1/boxes/{id}`
- `DELETE /v1/boxes/{id}`
- `POST /v1/boxes/{id}/exec`
- `POST /v1/boxes/{id}/extend`
- `GET /v1/boxes/{id}/tty` (WebSocket upgrade)

Execute a command:

```json
{"command":["sh","-lc","printf hello"],"timeout_seconds":300}
```

The response separates `stdout` and `stderr` and includes `exit_code`,
`timed_out`, `stdout_truncated`, and `stderr_truncated`. Each captured stream is
capped at 10 MiB. The default timeout is 300 seconds and the maximum is 3,600.

Extend a box from the time of the request:

```json
{"ttl_seconds":3600}
```

Errors consistently use this shape:

```json
{"error":{"code":"box_not_found","message":"box … was not found"}}
```

## Terminal Protocol

Connect to `/v1/boxes/{id}/tty` with the same bearer header. The first frame is
JSON text:

```json
{"type":"start","command":["/bin/sh"],"columns":80,"rows":24}
```

After that, binary frames carry terminal bytes in both directions. Resize with
a text frame:

```json
{"type":"resize","columns":120,"rows":40}
```

The server ends with a JSON text event containing `type: "exit"` and
`exit_code`, or `type: "error"` with `code` and `message`. A box allows only one
active exec or terminal session at a time.

## Swift Client

The `OpenBoxClient` library product depends only on Foundation networking:

```swift
import OpenBoxClient

let client = OpenBoxClient(
    baseURL: URL(string: "http://127.0.0.1:7070")!,
    token: token
)

let box = try await client.createBox(
    CreateBoxRequest(workspace: .ephemeral, ttlSeconds: 900)
)
let result = try await client.execute(
    id: box.id,
    request: ExecuteBoxRequest(command: ["sh", "-lc", "echo hello"])
)
print(result.stdout)
try await client.deleteBox(id: box.id)
```

Use `client.terminal(id:)` for a `URLSessionWebSocketTask`-backed terminal
connection. Server implementation types such as Hummingbird are not exposed to
client library consumers.

## Limits and Lifecycle

- Box TTL: 900 seconds by default, 86,400 maximum.
- Per-box default: four CPUs and 4 GiB.
- Server defaults cap boxes at eight CPUs and 8 GiB.
- Startup reconciles saved state with labeled Apple containers, deletes
  expired boxes, removes missing records, and cleans managed orphans.
- Registered protected folders use durable staging under Application Support.
  Completed commands, including nonzero exits, sync back. Timed-out commands do
  not sync, and staging is retained if synchronization fails.
