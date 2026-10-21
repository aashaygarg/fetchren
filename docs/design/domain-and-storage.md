# Design: Domain Foundation and Local Storage

Status: **Implemented** for macOS (Assignments 005A and 005B). The domain
model lives in `packages/fetchren_core`; SQLite persistence and the v1
migration live in `packages/fetchren_storage_sqlite`.

## 1. Domain model

All types live in `packages/fetchren_core` (pure Dart; no Flutter or
`dart:io`).

```text
Workspace ──< Collection ──< Folder ──< Folder ...
                    │            └──< RequestItem
                    └──< RequestItem
```

| Type | Parent | Notes |
| --- | --- | --- |
| `Workspace` | none | Top-level container. |
| `Collection` | `workspaceId` | |
| `Folder` | `parentFolderId ?? collectionId` | Nestable. Carries `collectionId` for direct queries. |
| `RequestItem` | `folderId ?? collectionId` | Holds a `RequestTemplate`. Carries `collectionId`. |

Every entity carries `EntityMeta`:

| Field | Meaning |
| --- | --- |
| `id` | Random 128-bit hex string. Never reused; preserved across migrations. |
| `createdAt` / `updatedAt` | UTC. `updatedAt` never moves backwards, even under clock skew. |
| `version` | Local revision counter: 1 on create, +1 per change (including deletion). |
| `sortKey` | Order among siblings (see below). |
| `deletedAt` | Tombstone. Deleted records are kept so a deletion can propagate later. |

### Invariants enforced by `WorkspaceRepository`

- Inserts start at version 1. Updates must be exactly `stored + 1`; otherwise
  `StaleWriteException` (optimistic concurrency, no lost updates).
- Type, `createdAt`, workspace, and collection of an entity are immutable.
  Moving between folders within one collection is allowed.
- A live entity's parent must exist, be live, have the right type, and be in
  the same workspace and collection. Folders cannot become their own ancestor.
- Tombstones are written only by `softDelete`, which cascades to all live
  descendants. Restoring an entity (writing a live revision) does not restore
  its descendants.
- `transaction` is atomic and serialized. Reads inside it see its own writes.

`InMemoryWorkspaceRepository` is the reference implementation.
`runWorkspaceRepositoryContract` in `packages/fetchren_core_testing` defines
the behavior every implementation (in-memory and SQLite) must pass.

### Ordering

Sort keys are strings over `0-9a-z` that never end in `0`. `sortKeyBetween`
always produces a key between two neighbours, so inserting or moving one item
never rewrites its siblings. This keeps future sync conflicts local to the moved
item. Equal keys (possible after concurrent edits on two devices) are ordered
by ID, which is deterministic on every device.

## 2. Templates vs resolved requests

| Type | Persisted | Sent | Purpose |
| --- | --- | --- | --- |
| `RequestTemplate` | Yes (inside `RequestItem`) | Never directly | What the user typed. May later contain `{{variables}}`. |
| `ResolvedRequest` | **Never** | Yes | Final values, produced by a `RequestResolver`. Has no ID and no serialization. |

The app sends requests only through
`RequestResolver.resolve(template) → ResolvedRequest → RequestExecutor.execute`.
`RequestExecutor` and `buildHttpRequest` accept only `ResolvedRequest`, so
resolved values (including future secrets) have no path back into a saved
template. Today `LiteralRequestResolver` copies values verbatim; variable
substitution will replace it without changing the executor.

## 3. SQLite persistence (implemented in Assignment 005B)

Code lives in `packages/fetchren_storage_sqlite` (pure Dart; uses `dart:io`
and `dart:ffi`, no Flutter).

### Package choice and platform evidence

`sqlite3` 3.7.1 (MIT, verified publisher simonbinder.eu, published October
2026). Its build hook downloads a prebuilt SQLite for the target platform from
the package's GitHub releases. Each download is checked against a SHA-256 hash
pinned in the pub.dev package, and the binaries carry SLSA level 3
attestations. `sqlite3_flutter_libs` is obsolete for 3.x and is not used.

| Platform | Evidence |
| --- | --- |
| macOS arm64, `dart test` | Verified: SQLite 3.54.0 loads; all package tests pass. |
| macOS arm64, sandboxed Flutter app | Verified: the real app opened, migrated, and persisted data in its container across separate launches (integration test plus independent `sqlite3` CLI inspection). |
| macOS x64 | **Unverified.** Prebuilt binary listed by the package. |
| Windows, Linux, iOS, Android | **Unverified.** Prebuilt binaries listed by the package; not built or run. |

Build-time notes:

- The first build needs network access to GitHub releases, unless the
  `url_pattern` hook option points at a mirror.
- Concurrent `dart run` invocations in one package race on re-bundling
  `.dart_tool/lib/libsqlite3.dylib`. Multi-process tests therefore build a
  worker once with `dart build cli`.

### Schema (version 1, `PRAGMA user_version = 1`)

```sql
CREATE TABLE nodes (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('workspace','collection','folder','request')),
  workspace_id TEXT NOT NULL,
  collection_id TEXT,                      -- folder/request only
  parent_id TEXT REFERENCES nodes(id),     -- null for workspaces
  name TEXT NOT NULL,
  sort_key TEXT NOT NULL,
  version INTEGER NOT NULL CHECK (version >= 1),
  created_at INTEGER NOT NULL,             -- UTC microseconds since epoch
  updated_at INTEGER NOT NULL,
  deleted_at INTEGER
) STRICT;
CREATE INDEX nodes_children ON nodes (parent_id, sort_key, id);
CREATE INDEX nodes_workspaces ON nodes (sort_key, id) WHERE kind = 'workspace';

CREATE TABLE request_templates (
  request_id TEXT PRIMARY KEY REFERENCES nodes(id),
  method TEXT NOT NULL, url TEXT NOT NULL,
  headers_json TEXT NOT NULL,              -- ordered [{id,name,value,enabled}]
  body TEXT NOT NULL
) STRICT;

CREATE TABLE app_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT;
```

- `user_version` numbers the **database** schema, independently of the v1
  JSON file format. The 005A plan proposed starting at 2; that was dropped as
  a needless coupling.
- Indexes match the only two queries in the repository: `children(parentId)`
  and `workspaces()`. A test checks with `EXPLAIN QUERY PLAN` that both use
  their index without a temporary sort.
- Connection settings: WAL, `synchronous = FULL`, `foreign_keys = ON`.
- Each repository holds two connections. A writer runs transactions as
  `BEGIN IMMEDIATE`; a reader serves committed data outside transactions.
- `busy_timeout` is 5 s during open and schema migration. Runtime writers
  retry `SQLITE_BUSY` asynchronously for up to 5 s, so another process's lock
  never blocks the UI isolate.
- Structural rules (versions, parent integrity, cycles, tombstones) come from
  `checkPut` and `tombstonesFor` in `fetchren_core`. The in-memory and SQLite
  repositories share them and cannot drift.
- Sensitive header values are cleared in the SQLite write path itself, so no
  caller can write credentials to disk.
- The same contract suite (`packages/fetchren_core_testing`) runs against
  both implementations.

### Schema migrations

- Forward-only `SchemaMigration(version, apply)` steps. Each runs in its own
  `BEGIN IMMEDIATE` transaction that also bumps `user_version`, and re-checks
  the version after taking the lock, in case another process just migrated.
- A failing step rolls back completely; the version is unchanged.
- **Newer schema:** `UnsupportedSchemaVersionException`. The file is not
  modified, and the app runs non-persistently with a visible message.
- **Not a database:** `SqliteException`, handled the same way. The file is
  never overwritten or "repaired".

## 4. Migrating `requests.json` (schema-v1 file)

`migrateLegacyV1` runs at every startup, after the default workspace and
collection exist. A durable marker in `app_meta['migration.legacy_v1']`
records the state:

| State | Meaning |
| --- | --- |
| *(absent)* | Never started. With no `requests.json`, nothing to do. |
| `inProgress` | An attempt started and has not finished (or the process died). |
| `completed` | Records committed and verified. **Final:** never overwritten. |
| `failed` | Input rejected; nothing imported; errors listed in the marker. |
| `skipped` | Failed earlier, and the source file has since been removed. |

Sequence:

1. Marker → `inProgress` (a compare-and-set transaction, refused if already
   `completed`).
2. Parse with `parseLegacyV1`. Every malformed entry, blank ID, or duplicate
   ID is reported by index. **Any** error fails the whole import; no record
   is dropped.
3. One transaction:
   - re-check the marker
   - write all records into the default collection, after existing siblings
   - read each back and compare it to the plan
   - marker → `completed`, with the record count and repair warnings
4. Rename `requests.json` to `requests.v1-migrated-<UTC time>.json`. It is
   **never deleted**.

All marker changes are compare-and-set, so concurrent app instances import
exactly once and never downgrade `completed`. This is tested
deterministically and with 4 simultaneous OS processes.

| Interrupted after | Next startup |
| --- | --- |
| step 1 | Retries from step 2 (tested with in-process and real process kills). |
| writes in step 3, before commit | Rolled back; retries (same tests). |
| step 3 commit | Sees `completed`; only retries the rename (same tests). |
| step 4 | Nothing to do. |

### Recovery procedure for a failed migration

The app starts normally with an empty or partially used default collection.
It shows "Saved requests from the previous version could not be imported…",
with the first error and the path of the untouched `requests.json`.

1. The full error list is in the marker:
   `sqlite3 workspace.sqlite "select value from app_meta where key='migration.legacy_v1'"`.
2. Either fix the listed entries in `requests.json`, for example by removing
   or renaming a duplicate ID, or restore the file from a backup.
3. Relaunch FetchRen. Failed imports are retried on every launch. On success,
   the records are added after any requests saved in the meantime.
4. To give up on the import, move `requests.json` out of the data directory.
   The marker becomes `skipped`, and the file remains wherever it was moved.

To fully reset (destructive; only with a backup), quit FetchRen and remove
`workspace.sqlite*`. If `requests.json` is still present, the next launch
imports it again.

### Migration and data-loss risks

- **All-or-nothing import:** one bad entry blocks every v1 record until it is
  fixed. Nothing is lost, but nothing is visible either. This is a CTO
  decision (open question 6).
- **Repairs:** a blank name becomes "Untitled request", and `updatedAt` before
  `createdAt` is set to `createdAt`. Both are recorded in the marker and shown
  once on the importing launch.
- **ID collision:** a v1 ID that already exists in the database fails the
  import and changes nothing.
- **Downgrade:** an older FetchRen finds no `requests.json` after migration
  and shows an empty list. The renamed file remains; this needs a release
  note.
- **Plain-text storage:** the database, WAL, and archived JSON are
  unencrypted, as before.

## 5. Open questions

1. **Moving between collections** is rejected, because `collectionId` is
   immutable. It needs an explicit subtree move.
2. **Restore semantics** for descendants deleted by the same cascade.
3. **Tombstone purge**: retention period and trigger (needed before sync).
4. **`version` vs a future server revision**: keep them as separate fields.
5. **Live refresh across windows:** a second FetchRen window sees another
   window's changes only after reloading; conflicting saves are detected and
   reported, not merged.
6. **v1 import policy:** all-or-nothing (current) vs importing valid entries
   and reporting the rest.
7. **Background isolate:** SQLite calls are synchronous on the UI isolate.
   This is fine at current sizes; revisit with history and large collections.
