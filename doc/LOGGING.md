# Logging

`potassiumProvider` uses three complementary diagnostic layers:

- Unified logging (`OSLog`) for developer diagnostics in the app and File
  Provider extension.
- `Snapshots.sqlite3` activity/conflict rows for the user-visible Activities
  timeline and retained support context.
- A redacted JSON support-log export created from the Activities tab.

These layers are deliberately separate. Unified logging can be more granular
for local development, while the SQLite trail and exported document only carry
the small set of sanitized fields that are useful to users and support.

## Categories And Correlation

`ProviderLog` is the shared logging namespace. Its categories are `app`,
`authentication`, `domain`, `runtime`, `file-provider`, `enumeration`,
`mutation`, `network`, `persistence`, `conflict`, `thumbnail`, and `export`.

`ProviderLogContext` creates a correlation ID, operation name, optional domain,
drive, and item context, plus a start time. File Provider activity rows receive
a correlation ID and measured duration. The `PotassiumKDriveService` records
sanitized unified-log spans for every kDrive request with an operation name,
correlation ID, duration, outcome, status code when available, and error
domain/code.

Network spans never include request URLs, query parameters, filenames, request
or response bodies, bearer tokens, refresh tokens, remote account identifiers,
or file bytes. The service does not currently expose a kDrive request ID, so the
optional durable `remoteRequestID` field remains empty unless a future typed API
surface provides one safely.

## Durable Activity Data

`KDriveProviderActivityEvent` records the operation, scope, outcome, severity,
and sanitized diagnostic data already shown in Activities. It additionally has
optional `correlationID`, `durationMilliseconds`, `networkOperation`,
`httpStatusCode`, and `remoteRequestID` fields. Existing databases migrate these
columns as nullable values.

`KDriveProviderEventSQLiteStore` retains the newest 5,000 activity rows by
default. This applies only to activity rows: unresolved, blocked, and failed
conflict rows remain until a user action or domain cleanup removes them. The
existing Clear action removes all activity rows and automatically resolved
conflicts, preserving unresolved conflict state.

## Support Export

The Activities toolbar exports a JSON document via the system file picker. Each
export receives a fresh salt and pseudonymizes domain, drive, item, correlation,
and request identifiers. It omits names, paths, staged-upload paths, and raw
conflict identifiers. Summaries and diagnostic text are scrubbed of known item
values, URLs, and paths before export.

The document includes event timestamps, operation kinds, outcomes, severities,
sanitized summaries, numeric error codes, duration, network operation, HTTP
status, and conflict-resolution state. It is not an export of the Apple unified
log and cannot be used to recover omitted secrets or private URLs.

## Rules For New Logging

- Use `ProviderLog` rather than creating a second subsystem/category namespace.
- Mark user-provided names, paths, account identifiers, and URLs private in
  unified logs; prefer logging counts, operations, and numeric codes.
- Durable summaries must be generic and safe to show in the Activities UI.
- Do not add tokens, raw API bodies, request headers, request URLs, file bytes,
  remote account information, or customer data to either logging layer.
- Add a migration and redaction test whenever a new durable diagnostic field is
  introduced.
