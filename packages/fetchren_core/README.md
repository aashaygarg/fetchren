# fetchren_core

The platform-independent domain model and contracts for FetchRen. This is
pure Dart: it must not import Flutter or `dart:io`.

It contains:

- `Workspace`, `Collection`, `Folder`, `RequestItem`, and `EntityMeta`
  (IDs, timestamps, version, ordering, tombstones)
- `RequestTemplate` (saved) vs `ResolvedRequest` (sent, never saved)
- the `WorkspaceRepository` contract and an in-memory reference implementation
- the schema-v1 `ApiRequest` record and the planned migration from it

See [docs/design/domain-and-storage.md](../../docs/design/domain-and-storage.md).

```sh
dart pub get
dart analyze
dart test
```
