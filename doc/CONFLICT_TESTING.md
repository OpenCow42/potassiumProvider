# Conflict testing

The conflict suite exercises production resolution code with two isolated
persistent clients, production callback executors, and separately opted-in Finder
races. `CONFLICT_RESOLUTION_TRUTH_TABLE.md` remains normative. Passing a model test
is not proof of a live server guarantee or a complete Finder acceptance run.

## Deterministic coverage

`ConflictCase` assigns stable IDs, engine, ordering, expected resolution, and
recovery assertions. `ConflictMatrixTests` uses a stateful typed service with
persistent metadata/bytes, conditional versions, parent validation, collision
allocation, and idempotency tokens. Each client retains its own cached version and
staged bytes across reconstruction. The service double's idempotency is a specified
model assumption; it is not new evidence of a kDrive guarantee. The catalog records
competing operations and unresolved finding IDs as well as expected policy. Lost
replacement responses and lost directory-create responses deliberately assert the
current conservative duplicate behavior and keep CR-009 unresolved; these are
policy regressions, not proof of exactly-once effects.

The plaintext matrix covers stale and missing versions, a competing write after
preflight, fail-on-conflict, rename/move combinations, normalized collisions,
edit versus Trash, stale deletion, lost create/conflict-copy responses, same-name identity replacement, repeated
metadata delivery, and parent
movement/removal. Failure injection covers offline, authentication, permissions,
throttling, quota, and cancellation. Assertions inspect identities, parentage,
versions, bytes, staged recovery contents, and subsequent reads.


The production create router is also exercised with `.mayAlreadyExist`. Tests
verify that existing bytes survive, file replay reuses the created identity under
the service-token model, and repeated directory delivery produces two usable
directories under current policy. This records CR-009 rather than asserting that
name matching safely reconciles identity. The router and both modification
executors are called by the real extension. Parameterized tests
cover combined contents/name/parent changes, contents plus Trash, and unsupported
fields. The vault executor now applies supported changes before Trash, uses the
committed revisions, and leaves unsupported fields pending. Missing content URLs
fail before mutation. Lifecycle tests run the plaintext executor under actual
`FileProviderOperationLifecycle` cancellation and check retained bytes, absence of
server mutation, and no late success. Error tests call the production mapper.

Vault matrix entries reuse the normative journal/service regressions. Additional
coverage runs 32 deterministic seeds, six competing writers, reverse delivery and
12 shuffled orders per seed. It checks preserved content revisions, canonical
results, conflict copies, and two encrypted SQLite stores reopened after persistence.
Metadata conflicts, stale purge, duplicate journal records, and causally valid
reproducer reduction have dedicated tests. Replay divergence or content/graph preservation failures write a synthetic
seed and minimized journal under the local temporary `potassium-conflict-failures`
directory; no live data or credential is included.

Run the unit target through Xcode, for example:

```sh
xcodebuild test -project potassiumProvider.xcodeproj \
  -scheme potassiumProvider-Stability -destination 'platform=macOS' \
  -only-testing:potassiumProviderTests
```

Use the standard scheme and the documented iPhone 17/iOS 26.5 and Apple Vision
Pro/visionOS 26.5 destinations for shared-runtime regression validation. Do not run
hosted tests or simulators during live Finder execution: they can register another
extension build or steal UI focus.

`SnapshotInitializationContentionTests` covers an environment exposed by the live
matrix: opening the production snapshot store during a temporary exclusive WAL
lock must wait, preserve existing data, and permit subsequent snapshot reads and
writes. The audit retains the failing old-order result and corrected platform runs.

## Independent live cases

```sh
# One focused reproduction, reusing the ordinary signed app:
scripts/run-finder-stability.sh --conflicts --case content-after-preflight --yes-live

# All six cases, serially; each gets a new run and generated subtree:
scripts/run-finder-stability.sh --conflicts --yes-live

# Acceptance profiles require explicit process lifecycle evidence:
scripts/run-finder-stability.sh --conflicts --extension-state fresh --yes-live
scripts/run-finder-stability.sh --conflicts --extension-state running --yes-live
```

The same `--extension-state` option is available with the original `--run` mode;
its sixteen scenarios and exact-item permanent-delete confirmation stay required.

The fresh profile verifies the lab first, waits for recorded work to settle, then
terminates only the exact signed embedded provider process. Domain access launches
the replacement while the recorder is active. It never terminates Finder, TextEdit,
or the system File Provider daemon. The running profile requires the existing
process to survive from before preflight until sealing; it does not start a process
and call that a warm run. Failed lifecycle evidence cannot certify a case.

Warm preparation explicitly signals the verified domain’s working-set enumerator.
Cached root resolution may produce no extension callback, so passive waiting cannot
establish readiness. Signal acknowledgement alone is insufficient: the same signed
process must produce completed diagnostic evidence within the existing 90-second
budget. Preflight failures retain a non-accepting, versioned
`launch-preparation-failed.json` with closed stage/reason and numeric error data.

Launch proof version 2 distinguishes a process from the replicated-provider objects
it hosts. Apple permits discarding and recreating those objects within one process.
Their initialization/invalidation spans must be complete and successful; they remain
visible in the timeline. Kernel birth, signing, and diagnostic process identity must
still match throughout. Missing/duplicated lifecycle telemetry and actual process
replacement reject acceptance. Historical version-1 proofs keep their original
stricter interpretation; failed old candidates are not upgraded into passes.

Use `--build` to explicitly rebuild/install. Consent handling and `--watch` are
shared with the Finder runner. Credentials remain in Keychain; the lab is the
existing authorized plaintext root under `Private`. No encrypted vault is provisioned.

| Case | Controlled ordering and required result |
| --- | --- |
| `content-before-preflight` | Hold after staging but before metadata lookup; competing remote edit commits; both byte streams must survive under distinct identities. |
| `content-after-preflight` | Hold after matching version preflight; competing replacement commits; the real conditional write conflicts and both versions survive. |
| `rename-rename` | Remote rename commits while the Finder rename is held after preflight; local rename intent wins on the same identity. |
| `move-move` | Remote move commits while the Finder move is held after preflight; local destination wins and bytes stay unchanged. |
| `edit-rename` | Remote rename commits while the Finder edit is held; edited bytes and the remote name both survive. |
| `edit-move` | Remote move commits while the Finder edit is held; edited bytes and the remote destination both survive. |

Targeted preparation creates a fresh run root and sibling destinations, then binds
and opens the root. It does not depend on the original suite’s deep-folder seed.
Each selected race still materializes its own file through Finder, binds every
mutation target, and verifies its destinations. The original suite retains the
full nested hierarchy, seed, and navigation assertions. Completed remote fixture
batches request one `.workingSet` refresh; individual-folder native signals are
ignored for replicated providers. Signal acknowledgement never satisfies UI,
remote-state, or callback assertions. The native working-set refresh target does
not expand the selected case’s subject set to all domain callbacks; complete global
settling remains a separate requirement before sealing.

Every result is selected in Finder, captured locally, reopened through Finder in
TextEdit, and byte-checked. Gate files are scoped to run, case, salted item alias,
correlation, unique attempt, and scheduling point. An old release cannot satisfy a
later case. Cancellation/expiry ends the held attempt; overlapping claims fail
instead of bypassing the gate. Direct API calls perform the competing mutation and
verification only. The competing metadata and bytes must be read back while
the local attempt is held; an accepted asynchronous move response does not prove
that ordering. The attempt-scoped competitor verification record is mandatory for
new version 3 profile results and the original preserve-both scenario.

`conflict-profile.json` declares the narrower selection. The ordinary immutable
Finder report still has all 16 entries; unrelated scenarios are explicitly
`notSelectedForConflictProfile`. Sealing validates the selected case's exact gate
and callback evidence. One targeted success never becomes a 16-scenario pass.
Failed fixtures, screenshots, and diagnostics remain available. A sealing rejection retains a non-accepting `finder-evidence-rejected.json` candidate with a closed reason; it never replaces the required final report and summary. Complete correlated spans include their terminals during monitored settling. Finder and TextEdit
cleanup addresses only owned windows/documents; dirty generated documents are saved,
never silently discarded. An unavailable cleanup control leaves incomplete evidence.

## Acceptance and remaining limitations

The complete six-case fresh and already-running profiles passed on implementation
`d4b5323`, with twelve sealed evidence bundles. Independent verification confirmed
one signed build, six fresh processes, a continuous warm process, actual competing
commits, reopened bytes, screenshots, complete diagnostic spans, and healthy final
reports. The earlier accepted baseline `05e8e5f` and intervening failed bundles
remain preserved. The audit records exact run IDs and the focused corrections.

Latest finalized validation: 463 macOS Stability tests, 395 standard macOS tests,
379 iOS Simulator tests, and 379 visionOS Simulator tests passed, with zero
failed/skipped/expected failures. The generic visionOS build succeeded. The last
changes are confined to macOS Stability; shared-runtime results cover the provider
lifecycle correction. `FileProviderBackgroundWorkTests` verifies cancellation,
replacement-instance independence, and late-registration rejection. A retained
failed-preparation trace also verifies actual materialization-child cancellation
during invalidation, mitigating CR-024 without converting that failure to a pass.

These conflict profiles do not certify the separate sixteen-scenario suite. Its
complete fresh and already-running acceptance remains open; earlier runs verified
ten scenarios through Trash, and the strengthened Restore path and subsequent
scenarios still need complete verification. Large materialized-set latency remains
unresolved. Live results are in `STABILITY_LOOP_AUDIT.md`.

Keep permanent-delete CR-013 open. The six conflict cases do not permanently delete
fixtures. Permanent deletion in the original suite still requires exact generated
item confirmation. Directory-create reconciliation, ambiguous replacement success,
and server-dependent guarantees must not be inferred from the controlled service.
