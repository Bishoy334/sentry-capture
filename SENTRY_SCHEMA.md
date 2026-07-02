# The Sentry Record Schema

The shared, local-first data contract for every Sentry app. Sentry Capture is
the first implementation; finance, journal, health, screen-time and the
launcher adopt the same envelope so any app (or a shell script, or the local
LLM) can read any record without an SDK.

## Principles

- **Local disk is the authoritative copy.** Every record is a real file plus a
  JSON manifest in a per-record folder. No feature depends on a server.
  Home-server sync, when it arrives, is a secondary copy — the schema is
  sync-friendly (stable UUIDs, content hashes, no single-machine assumptions)
  but sync itself is out of scope.
- **Open and inspectable.** Plain JSON manifests with media sidecars. `jq`,
  Spotlight, FSEvents watchers and the local LLM all work on it directly.
- **Fixed message sets at every active boundary.** URL schemes and any future
  local service expose a whitelisted set of actions, never arbitrary RPC.

## Layout

Each app owns a sibling folder under the ecosystem root `~/Sentry/`:

```
~/Sentry/
  captures/            # sentry.capture (this app)
    <uuid>/
      <media file>     # e.g. "Sentry Capture 2026-07-03 at 09.12.44.png"
      capture.sentryshot   # optional re-editable annotation project
      manifest.json
  apps/                # destination registry (see below)
  finance/ journal/ …  # future siblings, same pattern
```

One folder per record, named by the record's `id`. The folder is the unit of
sync/backup/delete.

## The envelope (generic — every Sentry record uses this)

```jsonc
{
  "schema": "sentry.capture/v1",   // "<app-domain>/v<major>" — parsers gate on this
  "id": "F0E9…-UUID",              // stable across machines, never reused
  "app": "sentry.capture",         // producing app
  "kind": "screenshot",            // app-domain vocabulary, see body sections
  "createdAt": "2026-07-03T09:12:44+10:00",  // ISO-8601 with offset
  "modifiedAt": null,              // set on any re-export / edit
  "source": {                      // where the record came from, all optional
    "appBundleId": "com.google.Chrome",
    "appName": "Google Chrome",
    "windowTitle": "Receipt — Stripe",
    "display": 1
  },
  "tags": [],                      // user/app-applied labels
  "notes": null,                   // freeform user text
  "hash": "sha256:…"               // content hash of the primary media/payload,
                                   // null until computed (filled asynchronously)
  // …app-specific body fields follow, defined per schema domain
}
```

Envelope rules:

- Producers MUST write `schema`, `id`, `app`, `kind`, `createdAt`.
- Consumers MUST ignore fields they don't understand (forward compatibility)
  and MUST NOT write fields outside `tags`/`notes` on records they don't own.
- A major-version bump in `schema` means breaking changes; minor additions are
  just new optional fields.

## Body: `sentry.capture/v1`

Capture-specific fields, flat alongside the envelope:

| Field | Type | Notes |
|---|---|---|
| `kind` | `"screenshot" \| "window" \| "scroll" \| "recording"` | area/fullscreen → `screenshot`; stitched → `scroll` |
| `media.path` | string | file name relative to the record folder |
| `media.type` | MIME | `image/png`, `image/jpeg`, `video/mp4`, `image/gif` |
| `media.width` / `media.height` | int | pixels |
| `media.bytes` | int | file size |
| `durationSeconds` | double? | recordings only |
| `ocrText` | string? | Vision text recognition, filled asynchronously after the record lands |
| `annotations.count` | int? | number of annotation objects baked into the media |
| `annotations.project` | string? | file name of the re-editable `.sentryshot` project |

## Destination registry (`~/Sentry/apps/`)

Sentry apps advertise themselves with one capability file each:

```jsonc
// ~/Sentry/apps/sentry.journal.json
{
  "app": "sentry.journal",
  "name": "Journal",
  "symbol": "book.closed",              // SF Symbol for menus
  "urlScheme": "sentry-journal",
  "accepts": ["sentry.capture/v1"]      // record schemas it can receive
}
```

Sentry Capture reads this folder to build its "Send to…" menus. Sending a
record = the record already being on disk + opening
`<urlScheme>://receive?record=<id>&schema=sentry.capture/v1`. The receiving
app resolves the id under `~/Sentry/` and reads the manifest itself — the URL
carries identifiers, never payloads.

## Transports (layered, cheapest first)

1. **The folder is the API.** Watch `~/Sentry/captures/` with FSEvents; a new
   `manifest.json` is the event. Ship first, zero coupling.
2. **URL schemes.** `sentry-capture://` accepts a fixed, validated action set
   (documented in the app README as they land). URL params are identifiers
   and enum values only — a URL scheme is an input trust boundary.
3. **Local command service** (future, when the launcher exists): JSON-RPC over
   a loopback-bound socket with a fixed registered message set —
   `capture(mode)`, `listRecents(filter)`, `getCapture(id)`, `ocr(id)`,
   `sendTo(app, id)` — possibly doubled as an MCP server for the local LLM.
   Not built until there is a client.
