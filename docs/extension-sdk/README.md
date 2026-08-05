# Keyestro Extension SDK v1

Keyestro extensions are executable directory bundles. They run in a dedicated
child process and exchange JSON-RPC 2.0 messages with Keyestro over standard
input and output. Any language that can read and write byte streams can
implement the protocol.

> **Trust boundary:** process isolation prevents an extension crash from
> crashing Keyestro, but it is not an operating-system sandbox. An extension
> runs with the current user's permissions and can bypass host APIs. Install
> only code you trust. Capabilities are disclosure and host-API authorization,
> not a complete security boundary.

The protocol version implemented here is `1.0`. A different major version is
rejected. New minor-version features require explicit negotiation.

## Package layout

An extension is a directory whose name conventionally ends in `.extension`:

```text
example.extension/
├── extension.json
├── bin/
│   └── extension
├── assets/
│   └── icon.png
└── LICENSE
```

The entry point must be either a native executable for the current Mac
architecture or an executable script with an absolute, valid shebang. Keyestro
copies a successfully inspected package into its managed Application Support
directory. It never removes quarantine attributes or bypasses Gatekeeper.

Package limits and validation:

- `extension.json`: at most 256 KiB.
- Entire package: at most 100 MiB and 1,000 regular files.
- Symbolic links are rejected.
- Absolute paths, NUL bytes, `..`, and paths resolving outside the package are
  rejected.
- The package is SHA-256 inventoried before and after copying.
- Directories become mode `0700`; non-executable files become `0600`.

## Manifest

Create `extension.json` at the package root:

```json
{
  "schemaVersion": 1,
  "id": "com.example.git-tools",
  "name": "Git Tools",
  "version": "1.2.0",
  "description": "Search and open repositories",
  "author": "Example",
  "license": "MIT",
  "executable": "bin/extension",
  "minimumHostVersion": "0.1.0",
  "capabilities": ["filesystem.read", "url.open"],
  "searchPolicy": "explicit",
  "executeTimeoutSeconds": 30,
  "commands": [
    {
      "id": "search-repositories",
      "title": "Search Repositories",
      "mode": "search",
      "keywords": ["git", "repo"]
    }
  ],
  "preferences": [
    {
      "name": "rootDirectory",
      "title": "Repository Directory",
      "type": "directory",
      "required": true
    }
  ]
}
```

Required fields are `schemaVersion`, `id`, `name`, `version`, `description`,
`author`, `license`, `executable`, and `minimumHostVersion`. The remaining
fields default to empty values, except `searchPolicy` (`explicit`) and
`executeTimeoutSeconds` (`30`).

Rules:

- `schemaVersion` must be `1`.
- `id` is a unique reverse-domain identifier, at most 128 characters.
- `version` and `minimumHostVersion` are SemVer values.
- There may be at most 100 commands, 100 preferences, and 50 capabilities.
- Command IDs and preference names must be unique. Every v1 command uses mode
  `search` and has at most 50 keywords.
- `executeTimeoutSeconds` is in the inclusive range 1–300.
- Preference `type` is one of `text`, `password`, `choice`, `file`,
  `directory`, or `toggle`.
- Preference names are ASCII-style identifiers beginning with a letter or `_`;
  subsequent characters may also contain digits, `.`, `_`, and `-`.
- A `choice` preference must declare 1–50 unique string values in `choices`.
  Other preference types must not declare `choices`.

### Search policy

`explicit` is the safe default. Keyestro initially displays a host-owned
gateway command in `@` mode; the extension receives query text only after the
user enters that extension command.

`global` allows the extension to participate in ordinary searches, but only
after the user separately enables query sharing for that extension in
Settings. Installing or enabling the extension does not grant global sharing.

### Capabilities

Keyestro v1 recognizes these capability strings in host behavior:

| Capability | Effect |
|---|---|
| `context.frontmostApplication` | Adds `context.frontmostBundleIdentifier` to `search` when available. |
| `filesystem.read` | Allows file/directory action arguments to be passed to `execute`. |
| `url.open` | Allows `openURL` for `http`, `https`, and `mailto` URLs. |
| `process.execute`, `filesystem.write`, `network` | Raises every published action's minimum risk to `externalSideEffect`. |

Unknown capability names are preserved for disclosure but grant no additional
host API. Keep the list minimal.

## Framing and JSON-RPC

Every message is a UTF-8 JSON-RPC 2.0 object preceded by one ASCII header:

```text
Content-Length: 128\r\n
\r\n
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
```

- Header terminator: exactly `\r\n\r\n`.
- Header limit: 8 KiB.
- Body limit: 1 MiB.
- `Content-Length` must appear exactly once and be a positive decimal integer.
- Request IDs may be integers or strings. Notifications omit `id`.
- A response has the matching `id` and exactly one of `result` or `error`.
- `stdout` is protocol-only. Write diagnostics to `stderr` or send `log`.
- Three consecutive invalid UTF-8 or JSON payloads terminate the process.
  Other framing or envelope violations terminate it immediately.

Writers must flush after a complete frame. Readers must handle fragmented and
coalesced frames; one read is not necessarily one message.

## Lifecycle

### 1. `initialize`

Keyestro sends a request and requires a response within two seconds:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": { "major": 1, "minor": 0 },
    "hostVersion": "0.1.0",
    "locale": "en_US",
    "theme": "system",
    "authorizedCapabilities": ["url.open"]
  }
}
```

Return the accepted major protocol version:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": { "protocolVersion": { "major": 1, "minor": 0 } }
}
```

Keyestro then sends the `initialized` notification. Do not begin protocol
output before responding to `initialize`.

### 2. `search`

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "search",
  "params": {
    "requestId": "6b96ff3b-2b1a-4ef6-b477-c9abce8545c8",
    "query": "keyestro",
    "limit": 50,
    "commandId": "search-repositories",
    "context": { "frontmostBundleIdentifier": "com.apple.Terminal" }
  }
}
```

`commandId` is present only for an explicit manifest command. `context` is
present only when both capability and data are available. The total search
deadline is two seconds; 300 ms to first useful batch is the target.

Return one final result in the response, or stream notifications named
`publishItems`. A response with `null` result means an empty final batch.

```json
{
  "jsonrpc": "2.0",
  "method": "publishItems",
  "params": {
    "requestId": "6b96ff3b-2b1a-4ef6-b477-c9abce8545c8",
    "items": [
      {
        "id": "repo:5f2d9c7a",
        "title": "Keyestro",
        "subtitle": "~/Developer/Keyestro",
        "icon": { "type": "asset", "path": "assets/icon.png" },
        "keywords": ["git", "launcher"],
        "actions": [
          {
            "id": "open",
            "title": "Open Repository",
            "risk": "safe",
            "behavior": "closeLauncher"
          }
        ],
        "defaultActionId": "open"
      }
    ],
    "isFinal": true
  }
}
```

Each batch may contain at most 50 unique item IDs. Item IDs are extension-local
and at most 256 UTF-8 bytes. Titles are at most 512 Unicode scalars; action IDs
must be unique per item and the default action must exist.

Icons are either an SF Symbol:

```json
{ "type": "symbol", "name": "shippingbox" }
```

or a package-relative PNG/JPEG asset:

```json
{ "type": "asset", "path": "assets/icon.png" }
```

Image metadata is decoded and limited to 16 million pixels. Paths are resolved
inside the installed package.

Action `risk` is `safe`, `externalSideEffect`, or `destructive`. Action
`behavior` is `closeLauncher`, `keepLauncherOpen`, or `replaceContent`.
Keyestro may raise, but never lower, the risk declared by an extension.

### 3. `cancel`

When a query is replaced or cancelled, Keyestro sends:

```json
{
  "jsonrpc": "2.0",
  "method": "cancel",
  "params": { "requestId": "6b96ff3b-2b1a-4ef6-b477-c9abce8545c8" }
}
```

Stop expensive work promptly and do not publish more batches for that request.
This is a notification and has no response. The same notification is sent for
a cancelled `execute`, using that execute request's `requestId`. If execution
has not stopped within 500 ms, Keyestro terminates the extension process group.

### 4. `execute`

Keyestro executes only an action that was published for the current item:

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "execute",
  "params": {
    "requestId": "39f5979c-547e-4b54-9d68-98aa980ae8ea",
    "itemId": "repo:5f2d9c7a",
    "actionId": "open",
    "arguments": {}
  }
}
```

Return one of:

```json
{ "jsonrpc": "2.0", "id": 3, "result": { "status": "success", "message": "Opened" } }
{ "jsonrpc": "2.0", "id": 3, "result": { "status": "cancelled" } }
{ "jsonrpc": "2.0", "id": 3, "result": { "status": "failure", "recovery": "Check access and retry." } }
```

The deadline is the manifest's `executeTimeoutSeconds` value. Text arguments
are scalar-bounded; file arguments require `filesystem.read` and arrive as
standardized absolute paths.

### 5. Shutdown

Keyestro sends a `shutdown` request with a two-second deadline, then an `exit`
notification. Respond to `shutdown`, release resources, and exit on `exit`.
Keyestro sends `SIGTERM` to the entire extension process group when disabling,
timing out, or removing an extension, then `SIGKILL` after 500 ms if needed.
Do not create detached background daemons.

## Extension-to-host methods

An extension may send these requests or notifications:

### `log` / `host/log`

```json
{
  "jsonrpc": "2.0",
  "method": "log",
  "params": { "level": "info", "message": "Indexed 12 repositories" }
}
```

Messages are bounded and recorded with private redaction. Never log secrets.
Writing text to stderr is also supported and bounded to 64 KiB per process.

### `showHUD`

```json
{
  "jsonrpc": "2.0",
  "id": "hud-1",
  "method": "showHUD",
  "params": { "message": "Repository opened" }
}
```

The host truncates the message to 512 Unicode scalars and responds with
`{"shown":true}`.

### `openURL`

Requires `url.open`. Only `https`, `http`, and `mailto` are accepted.

```json
{
  "jsonrpc": "2.0",
  "id": "url-1",
  "method": "openURL",
  "params": { "url": "https://example.com/repository" }
}
```

The result is `{"opened":true}` or `{"opened":false}`. A denied capability or
invalid scheme returns JSON-RPC error `-32001`.

### `readPreference`

The requested name must be declared in the manifest. Undeclared names receive
JSON-RPC error `-32602`; a missing value returns JSON `null`.

```json
{
  "jsonrpc": "2.0",
  "id": "pref-1",
  "method": "readPreference",
  "params": { "name": "rootDirectory" }
}
```

Unknown methods with an ID receive `-32601`. Notifications for unknown methods
are ignored.

### Preference storage and `preferencesChanged`

The host-owned editor validates values against the installed manifest. `text`,
`file`, `directory`, and `choice` values are strings; `toggle` is a JSON
boolean. File and directory values are standardized absolute paths. Non-secret
values are stored in SQLite and sent to an already-running extension after a
change:

```json
{
  "jsonrpc": "2.0",
  "method": "preferencesChanged",
  "params": { "values": { "rootDirectory": "/Users/example/Developer" } }
}
```

Clearing a non-secret value sends JSON `null` for that name. An extension that
starts later should call `readPreference` for its current values.

`password` values are stored only in the macOS Keychain. SQLite stores a row
with `value_json = NULL` to record that the secret is set. Secret values are
never included in `preferencesChanged`, diagnostics, configuration exports, or
logs. `readPreference` deliberately returns the secret string itself to the
extension process, so the Settings UI tells the user that the trusted native
extension receives that secret. Keep it only in memory and never log it.

## Resource controls and failure handling

- Resident memory soft limit: 256 MiB. Remaining above it for five seconds
  terminates the process.
- Pending inbound envelope queue: 256 messages.
- Three unexpected exits within 60 seconds open a per-session circuit breaker.
  The user can retry from Extension settings.
- Each extension receives a minimal environment, including only standard locale
  and temporary-directory values plus `KEYESTRO_EXTENSION_ID` and
  `KEYESTRO_PROTOCOL_VERSION`. Host secrets are not inherited.
- Each extension has its own process group; termination applies to descendants.

## Contract tools and examples

The repository contains complete Python and Swift examples under
`Examples/Extensions` and a single conformance executable with two product
names. From the repository root:

```sh
swift run --disable-keychain --disable-netrc launcher-extension-test \
  validate Examples/Extensions/PythonExample.extension

swift run --disable-keychain --disable-netrc launcher-extension-test \
  run Examples/Extensions/PythonExample.extension --query repo

swift run --disable-keychain --disable-netrc launcher-extension-test \
  fuzz-framing Examples/Extensions/PythonExample.extension

scripts/test-extension-examples.sh
```

`validate` checks package inventory, manifest, entry point, architecture, and
content hash. `run` performs handshake, search, the first published action, and
orderly shutdown. `fuzz-framing` exercises 1,000 fragmented/coalesced frame
layouts plus rejected length cases. The repository test suite also drives a
hanging fixture through search timeout and cancellation and verifies that both
the extension and its child process are terminated. Run all three commands and
the repository checks before distributing an extension.

For executable reference implementations, see:

- `Examples/Extensions/PythonExample.extension/bin/extension`
- `Examples/Extensions/SwiftExample/main.swift`
