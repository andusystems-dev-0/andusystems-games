# Save model — the three shapes

One API and one schema serve every game. Each game picks a `save_mode` in the games registry
(`apps/save-api/games-registry.yaml`); the API enforces it. The device is always the source of
truth — the server is durable backup + cross-device sync (see `identity.md`).

## Modes

| `save_mode` | Meaning | Keying | History | Use |
|---|---|---|---|---|
| `lww` (default) | One blob per player, overwritten each sync, **last-write-wins** | `(game_id, player_id, slot="default")` | none | Most games — a single progress blob |
| `lww_history` | LWW, but keep the last **N** revisions | same, single slot | `history_depth` revisions | Games that want undo/rollback/anti-cheat |
| `slots` | Multiple **named** saves per player | `(game_id, player_id, slot="<name>")` | optional per game | Manual save files / profiles / new-game-plus |

`slots` may also enable history (`lww_history` behavior per slot). The three modes are the same
mechanism with two flags: **multi-slot** on/off and **history depth** ≥ 0.

## Per-game registry entry

```yaml
# apps/save-api/games-registry.yaml  (reconciled by ArgoCD; API hot-reloads)
games:
  - slug: asteroid-drift
    save_mode: lww                 # lww | lww_history | slots
    history_depth: 0               # revisions to retain (lww_history / slots)
    max_slots: 1                   # >1 only for slots
    max_blob_bytes: 262144         # 256 KiB — reject larger; offload path below
    conflict: last_write_wins      # last_write_wins | reject_stale (client resolves)
  - slug: dungeon-scribe
    save_mode: slots
    history_depth: 3
    max_slots: 8
    max_blob_bytes: 1048576        # 1 MiB
    conflict: reject_stale
```

- The registry is **GitOps** — adding/adjusting a game is a PR to this file; prod and UAT read the
  same registry against separate databases.
- `max_blob_bytes` is enforced on write (413 if exceeded). Blobs are opaque to the server (bytea /
  jsonb) — the game owns the format; version the format inside the blob.

## Versioning & conflicts

- Every save row carries a monotonically increasing **`version`** (server-assigned) and an
  **`etag`**. Clients send `If-Match: <etag>` (or `client_version`) on `PUT`.
- `conflict: last_write_wins` → server accepts and bumps version (default; simplest, fits
  save-on-close).
- `conflict: reject_stale` → server returns **409** with the current server blob; the SDK's
  conflict hook merges (used by `slots`/`lww_history` games that care).
- With `lww_history` / history-enabled slots, each accepted write also appends to `save_history`,
  pruned to `history_depth` (see `data-model.md`). `GET …/history` lists; `…/history/{version}`
  fetches a revision.

## Large blobs

Simple games have tiny saves — keep them **in Postgres**. If a game's `max_blob_bytes` exceeds the
inline threshold (default **256 KiB**, config `INLINE_BLOB_MAX`), the API stores the blob in **R2**
(`saves/<game>/<player>/<slot>/<version>`) and keeps only a pointer + checksum in Postgres. The API
surface is identical either way. This keeps Postgres small and fast while allowing occasional big
saves.

## Why this shape
One schema + config beats per-game tables or per-game services (D-004, D-006): adding game #N is a
registry line, the API never changes, and prod/UAT stay a single deployment each.
