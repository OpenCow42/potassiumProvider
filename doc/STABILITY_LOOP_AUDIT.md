# Stability Loop Implementation And Evidence Ledger

This file is the auditable implementation ledger for
[`STABILITY_LOOP_PLAN.md`](STABILITY_LOOP_PLAN.md). It contains no live account
data, private identifiers, URLs containing identifiers, request/response
bodies, or credentials. Historical milestone tables below describe their original
validation. Current live execution and acceptance are recorded separately here.

## 2026-09-10 — Conflict matrix continuation

The same PR now contains a stable two-engine conflict catalog, two persistent
synthetic plaintext clients, controlled preflight scheduling and failure injection,
production callback executors/error mapping, and vault replay permutations with
synthetic minimized reproducers. `doc/CONFLICT_TESTING.md` describes exact entry
points, case ordering, assertions, and the distinction between model assumptions
and real server guarantees.

- Finalized deterministic validation: Stability macOS `potassium-conflict-mac-07.xcresult`
  **414 passed**, standard macOS `potassium-conflict-standard-mac-01.xcresult`
  **378 passed**, iPhone 17/iOS 26.5 `potassium-conflict-ios-02.xcresult`
  **362 passed**, Apple Vision Pro/visionOS 26.5
  `potassium-conflict-vision-sim-01.xcresult` **362 passed**; each has zero failed,
  skipped, or expected failures. The signed generic visionOS build also succeeded
  (`potassium-conflict-vision-build-01.log`). After strengthening returned-name
  assertions, targeted Stability macOS `potassium-conflict-mac-08.xcresult`
  finalized **19 passed**, zero failed/skipped.
- The prior Mac06 and iOS01 bundles each retain one cancellation regression
  failure: the synthetic scheduling gate could release between its last loop
  cancellation check and return. Earliest divergence: the worker continued to the
  remote mutation after release. Classification: harness, high confidence. The
  gate now checks cancellation after release and the test waits for the actual
  worker terminal before asserting no effects. Mac07/iOS02 are the passing reruns;
  prior failing bundles remain available. No production cancellation guarantee
  was inferred from that faulty test gate.
- Callback inspection and the new regression exposed an encrypted contents+Trash
  bug: the prior early branch acknowledged contents without applying them.
  `VaultModificationExecutor` commits supported edits before Trash, uses the
  committed revisions, preserves pending unsupported fields, and prevents Trash
  on edit failure. Classification: provider; confidence high from source and
  deterministic executor tests. The normative register was updated in this change.
- `595b2e19-4d55-4813-a2bf-92af51b520cf`: targeted live content-after-preflight
  case failed at the first generated Finder row before the gate. Report: zero
  passed, one failed, fifteen deliberately unselected. The window closed and the
  failed bundle was sealed. Explicitly signaling each generated container did not
  resolve the intermittent empty listing. Root cause remains uncertain.
- `f5124f0a-d40a-44cb-a362-1c4e9919c33d`: the same targeted case exercised the
  real held conditional upload, competing remote edit, two preserved byte streams,
  Finder selection/screenshots, and reopening both versions through TextEdit.
  The report finalized with one passed and fifteen deliberately unselected;
  `summary.json` sealed after pending enumeration settled. The read-only AX probe
  observed the generated rows on this attempt. This is a targeted pass, not a
  sixteen-scenario acceptance result. No initialization events were present, so
  it does not establish a cold launch. Remaining live cases and cold/warm
  acceptance remain open. CR-013 is unchanged.

Latest checkpoint validation, after launch-evidence validation and additional replay
cases: Stability macOS `potassium-conflict-mac-11.xcresult` **418 passed**;
standard macOS `potassium-conflict-standard-mac-02.xcresult` **378 passed**;
iOS `potassium-conflict-ios-03.xcresult` **362 passed**; visionOS Simulator
`potassium-conflict-vision-sim-02.xcresult` **362 passed**. All are finalized with
zero failed/skipped/expected failures. Mac09/Mac10 retain initial build failures
from unavailable imported C/AX constants; Mac11 includes the corrected code.
The Go to Folder and fresh/running live paths compile but still need live evidence.

### Six-case live profile and remaining navigation failure

The first serial six-case profile produced six immutable bundles; each selected
case retains one result and fifteen deliberately unselected entries:

| Run | Case | Result |
| --- | --- | --- |
| `1fa6de2b-357f-427c-9642-d24e5fb40e62` | content-before-preflight | Passed |
| `62ba9b99-f444-4f0c-bf66-1178983435f2` | content-after-preflight | Passed |
| `da404627-f436-4530-a18c-efb9dea2912f` | rename-rename | Passed |
| `5482f043-e944-4bd9-9f6d-09ec45b7f978` | move-move | Failed before the scheduling gate; generated row absent |
| `582be3ac-92b1-4293-8556-ef1a3a339f24` | edit-rename | Failed before the scheduling gate; generated row absent |
| `8f4840b4-e63e-439d-b8d3-c83986bae5ac` | edit-move | Failed before the scheduling gate; generated row absent |

The failures expected the exact generated file in the bound run folder. Observed:
matching parent/window/list view, zero matching labels, and two AX busy indicators.
Read-only snapshot inspection found the expected Nested/Sibling/conflict children.
The run-folder enumeration spans `B61AAE52-078B-48AC-AE8A-8BD3E19AB715`
(move-move) and `24C583DF-F7E1-4C1C-91B9-E25F4697DDEB` (edit-rename)
completed in 363 ms and 159 ms respectively. These are supporting observations,
not proof that Finder received or rendered the observer result. Classification:
UI automation/environment remains unresolved; root-cause confidence low. Reproduce
with `--conflicts --case move-move --yes-live`. No competing mutation was triggered
in the failed cases. A native Go to Folder navigation path is being validated;
no fix or complete live acceptance is claimed yet.

All run-owned windows closed. Earlier bundles remain available. The invoking shell
also reported a parse error after the app exited because the script was edited
while that invocation was still reading it. The current script passes `bash -n`;
this separate harness-development error does not alter the six sealed app reports.
Do not edit the command script during a live invocation.

Targeted navigation rerun `63316860-231f-40c9-b575-276d186f4fe9`
(`--conflicts --case move-move --yes-live`) finalized one passed and fifteen
unselected entries. Go to Folder navigation exposed the exact generated row;
the actual Finder move reached its scheduling gate, the competing remote move
completed, the local destination won on the same identity, and the file reopened
with matching bytes. Owned windows closed and the bundle sealed. This is a passing
reproduction of the previously failing case, not proof that the intermittent
Finder issue is eliminated or that all live cases pass.

### Fresh-extension profile: five passed, delayed local move observation failed

The fresh profile used verified kernel births, signed code and matching initialization
terminals. Its first five cases sealed as passed:
`c7b545ba-27aa-4687-bf2f-2980b4ee8097` (content-before-preflight),
`19f413dd-04cf-484c-affc-573d8dbeb3a1` (content-after-preflight),
`7132ed32-3ebb-4fb8-83ad-acc227616db6` (rename-rename),
`fa96b9ab-acd1-4628-b8a5-2d7d160db4f0` (move-move), and
`75d63673-f6a5-444c-9619-d104ffe6bf4b` (edit-rename).
Each includes `extension-launch.json`; these are case results, not a complete
profile certificate. Launch timestamps retain microseconds because ISO-8601
whole-second encoding otherwise loses the process/recorder ordering. The targeted
`potassium-conflict-mac-12.xcresult` finalized 20 passed with zero failures/skips.

`2a5fcd7a-b29e-4318-824d-b85510399864` (edit-move) reached the actual gate
and failed at the immediate expected-local-destination assertion after server
metadata and byte verification. The UI trace had not yet begun reopening the result;
that identifies the destination guard as the earliest assertion divergence.
Competing remote move span `1E274C51-8960-4449-A203-6FEAFF3FEE8D`,
conditional replacement `5E212013-E5CB-442F-821C-3CEC094D91F5`, and its
parent modify callback `C75AE248-F637-4F39-8781-97C48D37CBA5` all completed.
Expected: the same item under the remote destination, with edited bytes and the
unchanged filename, visible and reopenable in Finder. Observed: backend state
passed, but the current provider URL did not yet satisfy the parent/name guard.
Classification: harness timing, high confidence for the immediate assertion gap;
the precise macOS propagation delay remains to be measured.

The runner now reuses a bounded destination observation for Restore and conflict
results, retaining exact parent/name and domain/item binding. A stale location
remains pending rather than success. `FinderRestoreObservationTests` adds a
stale-move/wrong-name/valid-location sequence and cancellation regression.
Reproduce with `--conflicts --case edit-move --extension-state fresh --yes-live`.
The failed bundle and fixtures are retained; its live rerun is pending.

Latest finalized validation after create-callback coverage, stronger vault replay
oracles and delayed-location handling: Stability macOS
`potassium-conflict-mac-13.xcresult` **423 passed**; standard macOS
`potassium-conflict-standard-mac-03.xcresult` **381 passed**; iOS
`potassium-conflict-ios-04.xcresult` **365 passed**; visionOS Simulator
`potassium-conflict-vision-sim-03.xcresult` **365 passed**. The signed generic
visionOS build succeeded (`potassium-conflict-vision-build-02.log`). Subsequent
original-run launch-option and required-evidence tests finalized
`potassium-conflict-mac-14.xcresult` **28 passed**. All have zero failed/skipped/
expected failures. Navigation now clears its previous selection before opening Go
to Folder because the provider may already have moved that selected identity.
The ordinary signed live build is being rerun with these changes.

### Fresh profile rerun: persistent edit/move divergence

The next complete fresh-extension profile again sealed five passes:
`c278d5dc-206b-4515-ad0e-8434778ed15a` (content-before-preflight),
`73c3dabc-abb5-469e-a273-5618f029c2c2` (content-after-preflight),
`2ab03433-09f9-4167-bdb6-d5612a60cf0d` (rename-rename),
`e11a5315-9f56-47e4-8b73-a92eca6a0a36` (move-move), and
`45d8484d-0b46-4f89-95ce-134096f5bd03` (edit-rename).

`704bbba7-b50f-4cc0-bc60-c2489a851859` (edit-move) failed and sealed.
Expected: edited bytes on the same server identity under the remote destination,
then the matching local destination and a successful Finder/TextEdit reopen.
Observed: server metadata and bytes passed; `parentMatches=false nameMatches=true`
persisted until the original 90-second deadline. Competing move
`4DC78AA7-F823-47A0-AA61-EC3F80FC48B5`, replacement
`7BA5059F-B37C-4C3A-961A-50363DCF6B71`, and modify callback
`BD3B8BAF-3060-4EFB-A171-41252F6E0027` completed. The prior immediate
assertion was too early, but waiting alone did not fix this failure. Classification
remains provider/environment pending returned-metadata evidence; confidence low
in the underlying cause. The report's harness/deadline classification describes
the failing observation, not a proven root cause. All owned windows closed and
earlier bundles remain intact. Reproduce with
`--conflicts --case edit-move --extension-state fresh --yes-live`.

Successful plaintext modify terminals now retain the existing sanitized metadata
fingerprint so a targeted reproduction can compare returned callback metadata to
the verified remote result. No mutation policy changed. Regression and live
reproduction results follow below. The original sixteen-scenario preserve-both
path now shares the independently selectable race's cancellable scheduling and
reopening assertions instead of retaining the older sequential gate flow.

Targeted diagnostic run `737ec849-789f-44b6-a58c-193a7c4ce023` sealed the
same local-parent deadline failure. The held contents callback
`FE5F48BF-2472-45E7-AD65-7C77DC10BBF8` returned metadata fingerprint
`2996D4BC-A3F4-4127-89E9-4276E6A8C85D`, which differed from the independently
verified remote result. The remote move `E4427365-6DBC-4EA6-B19C-E30A31DA609A`
and upload `A162DA88-179A-458E-860A-C604660B3AAC` completed before that
callback terminal. Classification: provider/API response reconciliation; high
confidence in the returned-metadata mismatch, pending confirmation of which
receipt field is stale. The upload adapter previously returned its receipt without
a metadata refresh. An experimental correction performed one lookup after a confirmed
upload and adopts metadata only when identity, drive, ETag, and size match that
receipt. Read failures/newer content preserve the receipt and never replay the
upload. `committedReplacementRefreshesOnlyMatchingContent` covers all three cases.
The diagnostic-only Mac15 bundle finalized **23 passed**, zero failed/skipped.
Finalized validation of the guarded metadata refresh: Stability macOS Mac17
**426 passed**, standard macOS04 **383 passed**, iOS06 **367 passed**,
visionOS Simulator05 **367 passed**, all with zero failures/skips/expected failures.
The signed generic visionOS03 build succeeded. Mac16/iOS05/visionOS Simulator04
each preserve one failure in the older recording-mock test, whose expected call
sequence omitted the new post-upload item lookup; the expectation now includes
that read. The new stateful post-upload regressions passed in those runs.
Experimental rerun `580ca004-b95e-4f0b-8f00-d6286aff8aa4` again sealed the
edit/move deadline failure with mismatching callback metadata and a stale local
parent. The extra read did not resolve the issue and was removed, together with
its experiment-specific tests. Its finalized validation is retained above as
historical evidence, not the final implementation.

Source inspection found that the typed move API returns `KDriveCancelResource`;
the runner previously released the local callback after that accepted response
without independently confirming the move. That did not prove the intended
ordering. The harness now waits for the competing metadata and bytes, then records
an immutable attempt-scoped verification while the gate is held, before releasing
it. Profile version 3 and original preserve-both sealing require that proof.
Barrier/profile tests reject proof before arrival, after release/cancellation,
for another fixture or attempt, and missing verification. The live reproduction
with this stronger ordering follows below. Earlier version 1/2 results remain
readable but cannot establish the new ordering evidence requirement.

`7ae44326-7d5b-4dc3-8942-51a77d76a898` verified competing server metadata
and bytes before gate release, then again failed the local-parent deadline.
Read-only cache inspection after settling found the returned fingerprint from
contents callback `739EFC0D-2CBF-46A2-8DEE-920A700C1932` matched the final
metadata under the expected destination. The generated file also existed under
Sibling and was absent from its old folder after settling. This corrects the prior
receipt diagnosis: the runner's comparison used a metadata snapshot obtained
before waiting for edited bytes, so its size could still describe the base file.
It now refetches metadata after byte verification. Confidence high in this harness
comparison defect; no stale upload-receipt guarantee is inferred.

The destination wait also preceded navigation into the destination, which could
leave that folder unenumerated. The runner now opens the already bound parent
first, then verifies the actual parent through stable item/domain identity and the
exact filename before reopening. It records both identity and path comparisons;
a mismatching identity never passes. Mac18 finalized **426 passed** for the ordering
change; targeted Mac19 finalized **14 passed** for destination identity and gate
proof. Both have zero failures/skips. The next ordinary signed live run includes
destination-first navigation; its outcome is pending.

## 2026-09-10 — Live Finder implementation in progress

PR #22 now targets `main`; all stability work continues on
`codex/file-provider-stability-loop`. The original plan and implementation through
`49ac27a`, plus the live suite at `d8718c2`, are included in that single PR.
The operator authorized the saved lab account and Keychain login. Authentication,
remote ownership, registration, and domain binding have passed real preflight.
The lab is a new child of the verified server-created `Private` folder. Neither
`Private`, the lab root, its marker, nor previous contents are disposable fixtures.

**Acceptance remains open:** there are no complete passing cold/warm Finder runs.
Permission checkpoints and skipped scenarios are not passes. Code implementing a
scenario does not establish that its selectors or provider behavior work live.

Implemented runner paths include all 16 scenarios, injectable fresh-window UI
driving, monotonic deadlines, monitored permission/confirmation panels, a scoped
post-preflight conflict barrier, exact target ancestry and provider binding,
item-specific diagnostic aliases, process/build identity, local row screenshots,
read-only watch, and immutable version 2 reports with correlated timelines.
Ordinary callbacks require successful terminals; the cancellation scenario
requires actual progress, cancellation, and a subsequent successful fetch of the
same item. The legacy global active-step pointer is not sufficient evidence.

### Findings and reproduction evidence

Current continuation evidence:

- **Current live failure:** `5711656b-7079-446a-a21a-6716126d63a5`
  finalized with zero passed, one failed, and fifteen skipped scenarios. The last
  live observation confirmed the owned window, expected parent, and list view,
  but no matching text row or other named element. The failure was reported as
  `windowMismatch`; the driver now preserves its last live observation instead of
  querying after the deadline and producing misleading binding flags. Classification:
  UI automation; the underlying cause remains uncertain. The preceding run
  `2bc01352-eedb-4bac-9292-ad266e98a179` failed at the same navigation stage.
  Both windows closed and their immutable failed reports remain available.

- **Restore assertion gap and re-trash failure:**
  `c43e7fd0-23eb-4121-b06f-3a4ab0d0f0d2` reported eleven passed, one failed,
  and four skipped scenarios. The completed Restore callback, remote identity,
  parent, and bytes were verified, but the UI assertion did not require the
  returned local URL to be under the restored parent. The following re-trash
  produced no matching mutation callback and remote Trash lookup remained 404.
  A stale local Trash URL is a hypothesis, not a confirmed provider defect.
  Classification: harness assertion gap, high confidence from source inspection;
  root cause of the missing re-trash remains uncertain. Restore now also waits
  for the exact local parent and filename before Finder selection. Regression
  coverage rejects a stale Trash location or wrong name. The historical eleven
  passes do not establish current Restore acceptance. No permanent-delete
  confirmation or deletion occurred. The strengthened live assertion remains
  unexercised because subsequent navigation failed.

- **Intermittent Finder listing:** `4f870547-58ff-44d3-9d85-d71f079cb3ac`
  exhausted the full navigation budget waiting for the first generated row. A
  read-only AX observer confirmed the exact run window, Finder foreground, and
  zero matching `Nested` text fields. Provider enumeration span
  `6148A63A-8459-4D48-ADC6-5670B82EC1AA` completed successfully; read-only
  inspection of the provider-owned snapshot database found both generated children
  in the run-root generations. This does not support an empty provider listing.
  Finder navigation now explicitly resolves the directory as an Apple Events alias
  before assigning its target. Later runs reproduced the UI failure, so alias
  coercion has not resolved it. List-view drift is also unsupported by the latest
  live observation. Reproduce with the documented opt-in command and inspect the
  first selection's closed observations; do not weaken the row assertion.

- **Recorder ordering:** the owned recorder now starts before context preflight,
  which can launch the extension. An injected regression emits an initialization
  event during preflight, then fails preflight; the event must survive and no final
  report may certify that incomplete run. Real initialization telemetry was still
  absent in the next live bundle. Plugin registration can precede command startup;
  its role is unproven. Full cold/warm lifecycle attestation remains open.

- **Current Mac follow-up validation:** `potassium-live-stability-mac-15.xcresult`
  finalized with 393 passed and zero failures/skips, including local Restore
  destination, recorder-before-preflight regressions, and the latest row-observation
  logging. The signed live build also succeeded. The previous shared-runtime results
  below remain applicable; subsequent edits are guarded by macOS/STABILITY.

- **Completed navigation and Restore race:** `dc49fe60-e9e5-45fe-8261-85fd4339f5cc` again passed
  ten scenarios, now including all six added navigation captures and the remote
  change proof. It verified the Trash metadata fallback and exact Finder selection,
  then invoked Restore. The provider callback
  `787D06E3-4F3F-4075-B44E-C48F6B144A31` and its remote mutation
  `20B899BE-5186-4934-B886-8B4E33D2AD22` completed successfully. The runner's
  active-item check `573C63B4-9FA9-4934-ABC9-755E89EB0CA1` raced the callback
  and returned 404, prematurely failing verification. Classification: harness;
  high confidence from callback/API ordering and source inspection. The focused
  fix gates verification on the exact attested Restore callback, keeps 404 pending,
  and still requires matching identity, parent, bytes, UI, and all diagnostic proof.
  New regression tests cover absent callbacks, pending 404, operational errors,
  and wrong identities/destinations. Complete Restore verification awaits rerun.
  The report finalized with 10 passed, 1 failed, 5 skipped; its window closed.

- **Navigation timing:** `983e7d51-38ba-4905-bdf2-7c9e19426d30` still
  exhausted the driver's early 10-second row wait. After removing that cutoff,
  `15a8d165-afae-446a-a337-0b2cc76dd68f` completed root, nested, Back,
  Forward, and parent captures (`200.png` through `205.png`) and verified history
  navigation. A read-only AX observer confirmed the generated folder's exact row
  appearing and becoming selected. The remote-change portion then exhausted the
  aggregate 90-second deadline, which had also included fixture preparation.
  Preparation now has a separate bounded 90-second phase; it must complete before
  the scenario budget starts. Its time and diagnostics remain in the report.
  This change requires a rerun. No complete navigation or Restore pass is claimed.
  The next run `947a40d9-6a97-45fb-9700-6a71fc6f3ca9` instead hit Apple Events
  -10006 before selection, so closed command labels were added for diagnosis.
  `0cf21c51-e88f-403c-9169-ad116c62c0b9` again completed all six navigation
  captures but exhausted its budget before the remote-change proof. The five
  read-only placeholder resolutions/domain bindings still preceded navigation
  inside its budget; those now finish in the bounded preparation phase.

- **Current finalized unit validation:** macOS Stability
  `potassium-live-stability-mac-11.xcresult`: 387 passed; standard macOS
  `potassium-live-standard-mac-03.xcresult`: 361 passed; iPhone 17/iOS 26.5
  `potassium-live-ios-07.xcresult`: 345 passed; Apple Vision Pro/visionOS 26.5
  `potassium-live-vision-sim-05.xcresult`: 345 passed. All have zero failures or
  skips. The signed generic visionOS build `potassium-live-vision-build-05.log`
  exited successfully. Simulator tests are kept separate from live Finder runs
  to avoid competing UI activation. A signed live rerun of the new row wait is
  in progress; full cold/warm acceptance remains open.

- **Navigation follow-up:** runs `730c6781-b416-4783-9a5d-4212762a80f5`
  and `4b2c1ec5-a8d9-45bf-8db5-c366295dd265` stopped at the first generated
  folder selection before any navigation capture. Both retained two completed UI
  actions (lab/root navigation), zero selected-row captures, and a selection timeout;
  their dedicated Finder windows closed and reports finalized. During the second
  run, a read-only Finder snapshot confirmed the expected generated root and zero
  selected items. An isolated selection of the first run's already rendered folder
  succeeded. Probable cause: assigning selection before Finder renders the new
  folder's rows. The driver now waits for the exact displayed row and revalidates
  its own front-window identity before assignment; regression tests reject missing
  rows and ignored selections. Live rerun is pending. These runs did not reach Restore.

- **Metadata-fix validation:** `potassium-live-stability-mac-10.xcresult`
  finalized with 385 passed and no failed/skipped tests. The iPhone 17/iOS 26.5
  result `potassium-live-ios-07.xcresult` finalized with 345 passed. The signed
  generic visionOS build `potassium-live-vision-build-05.log` exited successfully.
  Navigation selector changes made afterward require their own Mac/live rerun.

- **Restore metadata fix, live validation pending:** the metadata callback now uses
  `KDriveItemMetadataLookup` to consult typed Trash metadata only after active-item
  HTTP 404. It verifies drive/item identity, preserves operational errors, and
  reports `.noSuchItem` only after both endpoints return 404. It does not broaden
  mutation/content preflight. New regression tests cover successful fallback,
  authoritative absence, identity mismatch, operational failure, and cancellation.
  Evidence validation accepts a handled nested 404 only with matching successful
  Trash and enclosing metadata spans; this never replaces the Restore callback.

- **Commit-time validation:** `/private/tmp/potassium-live-stability-mac-09.xcresult`
  finalized with 375 passed, zero failed/skipped, including the added navigation
  milestone failure test. This validates the source being committed; it does
  not replace the outstanding live rerun of those additional captures.

- **Farthest live result:** `0c8fea91-5123-4c8f-87d7-54b7e451a9fc` passed the
  first ten scenarios, including verified TextEdit editing/upload, rename, move,
  and the provider's `modifyItem` Trash transition. Restore failed before its
  UI action: active-item metadata returned HTTP 404 in span
  `90C81DC4-C76A-4D87-8DE1-230929B3EFA5`, then the provider returned
  `.cannotSynchronize` (-2005) in parent span
  `3DAFD9B8-B676-43F3-A495-52BBFE75B915`. Source inspection confirms that
  `item(for:request:)` consults only active-item metadata, without a Trash lookup
  fallback in that build. The focused correction above is awaiting validation.
  The run finalized with 10 passed, 1 failed,
  5 skipped, and its Finder window closed. Its fixtures and evidence remain.
  Scenarios 11–16 and both complete cold/warm acceptance runs remain open.
- Navigation now captures generated rows at the root, nested levels, Back,
  Forward, and parent milestones; the sibling capture follows its remote
  change. A missing milestone capture stops further navigation. These added
  captures postdate the latest live bundle and require a live rerun.

- `/private/tmp/potassium-live-stability-mac-08.xcresult`: 374 passed, zero
  failed/skipped, including native TextEdit sequencing failure guards, fresh
  working-set metadata evidence, and pending-poll coalescing. The requested
  iPhone 17/iOS 26.5 and Apple Vision Pro/visionOS 26.5 runs finalized with
  335 passed each in `potassium-live-ios-06.xcresult` and
  `potassium-live-vision-sim-04.xcresult`. The signed generic visionOS build
  `potassium-live-vision-build-04.log` exited successfully. Current standard
  macOS validation and complete cold/warm live runs remain outstanding.
- `5d9ec73b-175e-436f-b558-5c9294dc818c`,
  `d3fffe35-dda6-4bed-9a87-146de8c07997`, and
  `2d333d69-822d-4cc0-afd8-5963b4ce18b6` each passed six scenarios, then
  failed editing. The French keyboard layout explains why a hard-coded US
  Command-A could quit TextEdit. Replacing shortcuts with an opened menu still
  left native menu tracking stuck, which the operator reported and force quit.
  The subsequent `1f8e7574-9fba-4e1e-bd3e-cf7bf4b669d3` stopped at hydration
  while the earlier menu was still blocked. All dedicated Finder windows closed.
  A fresh local generated-file probe now passes direct AXMenuItem Select All,
  Paste, Save, matching disk bytes, and exact-document closure. It also confirms
  that AXEdited belongs to the close button, not the TextEdit window. This local
  probe is diagnosis, not a live Finder scenario pass. The later ten-scenario
  live result above verifies the resulting TextEdit correction.

- `0901be6f-ba75-4dde-a1d7-70d5d7e7d80f` verified the first six scenarios,
  including entering the Finder-created directory with verified remote parentage.
  TextEdit did not contain the requested replacement after process-addressed
  synthetic keys; no content-change callback followed. The runner now verifies
  the editor text and Save acknowledgement before closing the exact document.
  An attempted WindowServer-key workaround was subsequently replaced by the
  verified native menu-item actions described above.
- `a431f636-8889-4a08-8e32-833547c1673b` verified navigation and hydration,
  then exhausted the eviction deadline after waiting for system stabilization.
  The contextual eviction command was invoked; no resource-busy alert was
  recorded. Global working-set polls took 19–61 seconds, including queue time,
  and did not report errors. Each materialization notification queued another
  full refresh. Pending notifications now share only a successful poll begun
  after their observations, with regression coverage for ordering and failure.
  The Finder window closed and the failed bundle was finalized. Rerun pending.

- `/private/tmp/potassium-live-stability-mac-05.xcresult` finalized with 363
  passed and zero failed/skipped, including the per-domain poll scheduling test.
- `67f1dda7-7d1b-4c77-a90f-eb5fff93e1e7` subsequently recorded 33 completed
  working-set refreshes, no failures, and no contention retries. This is live
  evidence for serializing immediate materialization polls with other polls.
  It still failed directory naming; all five earlier scenarios passed and the
  dedicated Finder window closed. The name editor is contained in the expected
  window bounds but absent from its child tree, selected-row tree, and ordinary
  AX parent/focused-window identity. An alternative checks the exact new Finder
  selection, editor value/process, verified front window ID, and fresh bounds.
  Its live result is pending; weak or ambiguous matches cannot pass.

- `/private/tmp/potassium-live-vision-build-03.log`: signed generic visionOS
  build completed successfully with `-allowProvisioningUpdates`. Xcode refreshed
  provisioning; the earlier missing-App-Groups profile blocker is superseded.
- `fef2a881-ccea-4e2e-8770-15f3f6a588b7` still recorded six exhausted snapshot
  refreshes alongside 33 successful refreshes. Bounded retries and equivalent
  result handling are not a complete resolution of working-set contention.
  Keep this finding open; do not describe a single recovered poll as a complete fix.

- `/private/tmp/potassium-live-ios-04.xcresult` and
  `/private/tmp/potassium-live-vision-sim-03.xcresult` each finalized with 330
  passed, zero failed/skipped on the requested iPhone 17/iOS 26.5 and Apple
  Vision Pro/visionOS 26.5 simulators. They include the shared snapshot retry,
  equivalent-result transaction checks, and strict contextual evidence tests.

- `/private/tmp/potassium-live-stability-mac-04.xcresult` finalized with 359
  passed, zero failed/skipped. This includes SQLite snapshot retry and Finder
  window-ownership regressions; later UI refinements need the final rerun.
- `47dae10c-d9ba-4c6f-8d1b-4f0b7db6635b` recorded 11 completed working-set
  refreshes and one recovered `concurrentSnapshot` checkpoint, with no failed
  refresh. This verifies the focused retry on a real concurrent enumeration.
- The operator observed and dismissed Finder's "Unable to Remove Download" /
  "Resource busy" alert. This establishes that the command was invoked; it was
  not simply a missing menu selector. The runner had sent TextEdit's close key
  without observing document closure. Waiting for the exact document window to
  disappear and the manager's documented testing stabilization barrier precedes
  eviction; a scoped detector records and dismisses this specific failure alert.
- `abb74c1a-43a8-4f04-a994-53fbf9042656` certified the first five scenarios:
  navigation, hydration, eviction, download, and Finder file creation. It closed
  its Finder window after failing directory creation (5 passed, 1 failed, 10
  skipped). The generated parent was correlated to its cached snapshot without
  exporting identifiers: Finder created the default folder name, with no rename
  callback. Replace the fixed entry delay with a fresh editable-name-field check.
  No full 16-scenario or cold/warm acceptance is established by this run.

2026-09-10 continuation: runs `6bd4ce12-06fa-4392-ac35-37afe3f09a11`,
`14e6edaa-05c8-4889-abb6-b8cea7e5bf73`, and
`75af7047-2894-4bb7-9c01-a3be17d9602e` each certified navigation and hydration,
then stopped at Finder eviction (2 passed, 1 failed, 13 skipped). The directory
date 400 and partial-activity 422 did not recur. This closes those reproduced
request defects, not broader working-set correctness or 16-scenario acceptance.

The next cleanup run, `5e82a9fb-1240-49ef-8363-6e4e52243658`, verified closure
of the run-owned Finder window after failure. Cleanup checks the created window
ID and kernel process start time (Finder's LaunchServices launch date can be nil).
`FinderNavigationTests` cover unrelated/reused process identities and observable
cleanup errors. Finder popup tracking can reject Apple Events with
`errFinderIsBusy` (-15260), documented in Apple's SDK `FinderRegistry.h`.
Await menu dismissal and bounded read-only readiness before another operation;
cleanup must remain monitored and cannot silently certify a failed close.

That run also classified both former unknown working-set failures as
`concurrentSnapshot`: all remote requests completed, then the atomic snapshot
commit rejected a container changed by concurrent enumeration. The focused fix
repeats the entire snapshot read and remote preparation at most twice, retaining
the throttle claim and successful watermark until an atomic commit succeeds.
Retries emit closed `concurrentSnapshot` checkpoints. Persistent contention still
fails; no stale write is forced. Regression injects real SQLite concurrent saves
and checks successful convergence plus bounded persistent failure and watermark
preservation. Current test and live rerun results remain pending.

| Finding | Expected / observed and earliest divergence | Confidence, fix, and regression |
| --- | --- | --- |
| Marker date codec mismatch | A freshly provisioned marker should verify after reloading configuration. Remote numeric dates retained fractions; local ISO8601 dates lost them, so equality rejected the same ownership marker before Finder started. | High. Canonicalize marker dates to seconds on creation and decoding without weakening UUID/drive/root/parent checks. `markerSurvivesRemoteAndDomainDateEncodings` covers the two codecs. Real registration resume subsequently verified the existing lab. |
| Stability host sandbox blocks assistive AX | Runner should request usable Accessibility access. The sandboxed host could not use the assistive APIs. | High; Apple's [sandbox restrictions](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox) corroborate. Only the macOS Stability containing app is outside App Sandbox; both extensions and standard profiles remain sandboxed. Signed entitlement inspection verified this boundary. |
| CLI sheet event loop and launcher connection | A permission pause should retain the run and respond to the panel. A bare RunLoop did not reliably dispatch the sheet; restarting the launcher also lost its stdout connection. | High for the harness lifecycle defect. Run NSApplication's event loop, ignore SIGPIPE, launch through LaunchServices with persistent private stdout/stderr. The paused run remained readable through the new panel. |
| Automation consent classification | An app needing first-time Apple Events consent should pause and request it. `errAEEventWouldRequireUserConsent` was classified as Finder unavailable. | High. Treat both consent statuses as checkpoints. A subsequent live preflight passed Finder Automation and Accessibility. |
| Ambiguous privacy grant / duplicate signed copies | Settings shows Screen Recording enabled, while the installed runner still receives denial. The ordinary `/Applications` app has a different designated signing requirement from the installed Stability app; current and rebuilt Stability requirements match. | Medium; duplicate registration is a supported hypothesis, not proven TCC internals. Reuse one installed bundle by default, with explicit `--build`, and ask the operator to bind the grant to that exact path. No privacy database modifications or broad resets. |
| Working-set partial-activity HTTP 422 | Working-set refresh should validate the partial-activity response and advance its durable watermark. A `listPartialActivities` failure with numeric status 422 preceded a failed `workingSetRefresh` span. | Resolved for the reproduced request: use upstream's `with=file`; ten requests succeeded in `0965c244-7ea6-457e-bc34-56cba76a1033`, with no recurrence in subsequent Finder runs. Snapshot contention is a separate finding. |

Preserved bundles live under the app group's `StabilityRuns/runs` directory:
`5a365b82-a543-4d84-9dc1-06619259ee56` (permission checkpoint),
`c235fa55-8253-4344-8443-425fc4ef5062` (launcher-interrupted, explicitly abandoned),
`84942857-a39e-4bb4-8e6e-56aa27a98bdc` (Automation classification failure), and
`ed3e55d5-3fb0-4897-a003-95cb3b543daa` (remaining Screen Recording checkpoint).
These bundles have zero scenario passes and must remain available for comparison.
Live completion no longer automatically prunes earlier bundles.

### Finalized validation to date

Subsequent live findings:

- `0965c244-7ea6-457e-bc34-56cba76a1033`: ten partial-activity requests succeeded
  after `with=file`; no 422 recurrence. Date-only directory mutations still
  failed with 400. Hidden-extension handling passed; selection verification
  remained blocked.
- `73bb9a3a-d0d5-4e3b-a4cc-83724c20c5dc` and
  `d9d0dab7-ca73-48dd-8d95-26979058ff56`: retained older Finder windows could
  have exactly equal titles and frames. Bind the front Apple Events window ID
  before using AX focus to disambiguate. A direct comparison also reproduced
  Finder's `count selection` returning zero while a fetched selection list
  contained one item. The runner now fetches and validates a single list snapshot.
- `e02376a2-19db-45c5-b213-72165a517fe4`: all navigation UI checks and cropped
  row screenshot capture succeeded; diagnostic certification correctly failed
  on directory date updates. A separate-correlation API comparison accepted the
  untouched generated file's existing timestamp. Both rejected subjects matched
  directory types in the provider's own snapshot cache (no raw identifiers or
  data exported). Omitting directory content dates did not prevent callbacks in
  `672f3d5e-6497-4fa7-b9d7-084710480fa3`; that experiment was reverted. The
  supported fix refetches and returns the server directory date without issuing
  the file-only request. The SDK's `NSFileProviderReplicatedExtension.h` describes
  propagation of differing non-pending returned fields to disk. Regression:
  directory timestamp server-wins and regular-file mutation/refetch tests in
  `KDriveMutationCoordinatorTests`; live rerun pending.
- Installer correction: an absent obsolete plug-in registration is normal, but
  `pluginkit -r` returned nonzero between backup and install. The verified staged
  bundle was installed and its previous bundle retained. Cleanup is now best
  effort after install; the install path has a rollback guard. No lab/domain or
  credential was removed.

The first real navigation bundle, `aed38bf2-8864-4d67-a3ae-f990c3c1596d`,
finalized with one failed scenario and fifteen skipped. Fresh extension build
attestation passed. Finder reached both nested levels, Back/Forward/parent, and
Sibling, where the generated remote fixture was present. The UI exposed the
display name without its extension, while the selector required the full filename;
this was the immediate 90-second assertion timeout. The selector now obtains the
display name for the exact bound URL and rejects ambiguous labels. Its regression
covers hidden extensions and duplicate labels; live rerun is required. This does
not hide the provider failures independently recorded in the same bundle:
`listPartialActivities` 422 and `updateModificationDate` 400 on date-only
`modifyItem` callbacks. Failure classification and API diagnosis continue.

All commands use the root Xcode project and `-only-testing:potassiumProviderTests`.
No simulator test invokes the live account. Result paths are local, untracked.

| Destination / profile | Finalized result | Scope caveat |
| --- | --- | --- |
| macOS Stability | `/private/tmp/potassium-live-tests-mac-02.xcresult`: 339 passed, 0 failed/skipped | Predates the latest confinement, callback waiter, and validation-field additions; final rerun required. |
| iPhone 17 / iOS 26.5 | `/private/tmp/potassium-live-ios-01.xcresult`: 315 passed, 0 failed/skipped | Updated shared suite is being rerun. |
| Apple Vision Pro / visionOS 26.5 | `/private/tmp/potassium-live-vision-sim-02.xcresult`: 321 passed, 0 failed/skipped | Includes confinement and waiter tests; predates validation-field additions. The earlier cancellation test fixture had impossible timestamp ordering and was corrected before this run. |
| generic visionOS | `/private/tmp/potassium-live-vision-build-02.log`: build succeeded with `CODE_SIGNING_ALLOWED=NO` | Signed device build is blocked by the locally selected actions-extension profile lacking App Groups. This is compile validation, not a signed-device pass. |

Still required: finalized current macOS standard/Stability results and updated
shared-platform checks, real Finder selector diagnosis, complete healthy evidence
for all 16 scenarios twice, and focused regression/rerun evidence for each live
failure. CR-013 remains open regardless of disposable permanent-deletion success.

## Evidence Revisions

| Source | Pinned revision | Role |
| --- | --- | --- |
| potassiumChannel | tag `0.3.0`, commit `db829f1f2bd8c2113a529c9c521bd5cdfb5ef4dc` | Typed request/service behavior used by this project |
| Infomaniak public API documentation | accessed 2026-08-31; page-data version `f77cce2c8a7919ddbfd690c32bd0a019`; navigation snapshot SHA-256 `b831cb542fedc9f06f2b1e28f98c1ec86a6d9a98ef00d20b2c3de95dac0d178d` | Published route and field contract; no public source revision is exposed |
| Infomaniak iOS | `90c2e2560630b075b77b9e87b46b44d385a05283` | Behavioral comparison only; GPL code is not copied |
| Infomaniak Android | `25e07993e87e8ae50f7c73aeaf4c6802eef1d434`; Core submodule `7037dab1428b8eb23021db74f5881c4a39fdba83` | Behavioral comparison only; GPL code is not copied |
| Infomaniak desktop | `f72372661e79744c243fd4963465aaae92a6eba7` | Behavioral comparison only; GPL code is not copied |

## Ordered Milestones

| Milestone | Implementation state | Focused validation | Adversarial review | Commit |
| --- | --- | --- | --- | --- |
| Stability build profile and JSONL event store | implemented; reviewer fixes applied | 13 macOS `StabilityDiagnosticsTests` passed 2026-08-31 | all actionable findings fixed | `2fd9fbb` |
| Callback and network instrumentation | implemented; final reviewer repairs applied | signed `build-for-testing` passed; 27/27 focused executions passed | final bounded pass: no remaining finding | `c348d0c` |
| Stability Lab and safe root lifecycle | implemented; reviewer fixes applied | Stability graph built; 47/47 focused executions passed | final pass: no remaining actionable defect | `871c04d` |
| Finder Accessibility runner and checkpoints | implemented; reviewer repairs applied | current signed Stability test graph built with Finder-only entitlements; all 33 focused cases reported passed in both scheme executions; standard macOS, iOS Simulator, and generic visionOS app graphs built | all actionable findings fixed | `347b2a3` |
| API evidence matrix and adapter corrections | implemented; reviewer repairs applied | signed Stability graph built; final eight-case API slice reported 16/16 passes; historical macOS finalization evidence is superseded by the 2026-09-08 finalized profile results below | final bounded pass: no remaining blocker | `c61cf6e` |
| Cross-platform completion validation | complete; no live checks run | macOS, iPhone 17 iOS 26.5 Simulator, Apple Vision Pro visionOS 26.5 Simulator test graphs built; generic visionOS built; 2026-09-08 finalized macOS profile results replace the earlier incomplete macOS-host observation | final evidence pass: no remaining finding | `5acee67` |
| macOS test-profile reliability | implemented; no production behavior changed | finalized standard unit result: 319 passed; finalized Stability unit result: 327 passed; both zero failed/skipped. Shared schemes now explicitly disable coverage. | profile-boundary and ordinary-domain fail-closed coverage reviewed; local full UI-host rerun remains an environment limitation | `test: isolate profile-specific macOS tests`; `chore: stabilize macOS test schemes` |

## Architecture Integration Checklist

- Event-store construction sites: app model, File Provider runtime (including
  fallback load), contextual-action runtime, and app-group uninstall cleanup.
- Snapshot SQLite table creation no longer creates activity/conflict tables.
  Snapshots, anchors, enumerator state, and working-set state remain SQLite.
- `Stability` exists on the project and all six targets with `STABILITY`,
  testability, and unoptimized Swift. The two shared Stability schemes contain
  no credential arguments or environment variables.
- The unit-test target cannot import the File Provider extension executable.
  Callback behavior must therefore be implemented in or extracted to the
  shared core and invoked by the extension entry points.
- Runtime callback coverage must include extension initialization/invalidation,
  materialization checks, item lookup, content fetch, create/modify/delete,
  enumerator creation/invalidation, item/anchor/change enumeration, working-set
  refresh, known-folder work, thumbnails, and contextual actions.
- Risks still open for later milestones: permission/checkpoint behavior, safe
  remote-root ownership proof, and ensuring docs/truth-table evidence stays synchronized.
  Callback exactly-once semantics and transfer cancellation now share the
  actor-isolated diagnostic lifecycle and have focused race coverage.
  Active-run, append/read/finish, and retention transitions now share a
  cross-process lifecycle lock and crash-durable file transitions.

## Milestone 1 Decision Records

| Decision | Evidence | Live result | Chosen behavior | Tests | Truth-table impact |
| --- | --- | --- | --- | --- | --- |
| Build/profile isolation | Project target/scheme map at `efd5925`; plan requirements | not applicable | Reuse production IDs/groups/entitlements; define `STABILITY` in a distinct configuration and omit UI automation from its unit Test action | build-settings inspection; `StabilityDiagnosticsTests` | none; no mutation behavior changed |
| Event-store selection | Four production construction sites and existing event protocols | not applicable | Standard uses SQLite; Stability uses only the active run's JSONL and never silently falls back | factory-selection test | cleanup implementation reviewed; mutation/conflict decisions unchanged |
| SQLite boundary | `KDriveSnapshotSQLiteStore.createTables` previously called event-table creation | not applicable | Snapshot/anchor/working-set SQLite remains; activity/conflict tables are independent and JSONL-only in Stability | factory test asserts both JSONL and SQLite exist | none |
| Private-data boundary | `AGENTS.md`, plan invariants, existing support-export model | not applicable | Redact before encoding; closed-enum diagnostic schema; no names, paths, item/request/account/drive identifiers, raw URLs/bodies/headers/data/share links | raw-byte private-value test; enum-only encoding test | conflict event fields are redacted, decision state preserved |
| JSONL durability | Plan requirement for app/extension/actions concurrent writers | not applicable | lifecycle plus event-file locks, complete-record append, `fsync`; ignore and truncate only an unterminated tail; corruption otherwise surfaces; reject before the 250 MiB active-event limit | real subprocess and two-store writers; concurrent coordinators; interrupted-tail, corruption, capacity, post-finish, and symlink tests | unresolved conflict records replay unchanged except private fields |
| Clear/removal and retention | Existing event-store semantics and safe cleanup rules | not applicable | append tombstones; preserve unresolved conflicts; prune only whole completed bundles, never active/incomplete | replay and completed-only retention tests | conflict cleanup semantics unchanged |

## Milestone 2 Decision Records

| Decision | Evidence | Live result | Chosen behavior | Tests | Truth-table impact |
| --- | --- | --- | --- | --- | --- |
| Callback lifecycle | Apple replicated File Provider callback/cancellation contract; existing `FileProviderOperationLifecycle` | not run | start once; first completion/failure/cancellation wins; attempt the terminal append before invoking File Provider completion so run finalization cannot lose it | span terminal-race and lifecycle failure/cancellation tests | observes existing mutation outcomes; no decision changes |
| Correlation | plan privacy boundary and structured-concurrency task inheritance | not applicable | propagate only a random callback UUID through `TaskLocal`; give each nested span a separate stable UUID so concurrent child operations can be paired | nested-correlation and span-identity tests | no mutation/conflict change |
| Typed request evidence | potassiumChannel `0.3.0` service calls and the route map | not run | record only enum operation, route template, option shape, phase, duration, and class; never raw request data | drive-discovery request/diagnostic test; schema/redaction tests | no request behavior change |
| Transfer cancellation | potassiumChannel progress/cancel operation and File Provider progress contract | not run | start lazily when consumed or cancelled; forward progress by deduplicated buckets; race cancel and value completion through one terminal gate | lazy transfer, progress, forwarding, and terminal-race tests | retries and conflict policies unchanged |
| HTTP and callback diagnostic class | API rejection classifier plus `NSFileProviderError.Code`, without retaining body/header/user-info metadata | not run | map closed HTTP and File Provider recovery classes; cancellation records `cancelled`; expected share-link 404 is a successful optional result | closed classifier tests including 429/507 and File Provider recovery cases; optional-404 adapter test | Milestone 5 maps 408/429 and oversized direct uploads to recoverable File Provider errors; diagnostic payloads remain closed |
| Active-run binding | JSONL writers reject sealed runs and a Stability run may start after a long-lived app/extension object | not applicable | resolve the active recorder at callback or service-construction time; never cache a missing or sealed run writer for the object lifetime | factory/run lifecycle tests plus reviewer inspection | no mutation/conflict change |

## Review And Validation Log

### 2026-09-09 — macOS test-profile reliability repair

- `FinderStabilityCommandTests` now compiles only under `os(macOS) &&
  STABILITY`. Five ordinary-domain app-model tests and the concurrent ordinary
  domain-add setup test compile only in the standard profile. A Stability-only
  regression proves `addDomain` rejects an ordinary domain before either
  registration or persistence. The related Stability Lab registration-race
  test is also profile-gated because it exercises Stability provisioning.
  This changes no File Provider mutation, version, retry, cleanup, or error
  mapping decision.
- Before the scheme edit, the following credential-free macOS commands created
  finalized result bundles on macOS 26.6.2. The standard unit result at
  `/tmp/potassium-provider-m1-standard-rerun/Logs/Test/Test-potassiumProvider-2026.09.08_23-43-42-+0200.xcresult`
  reports `result: Passed`, 319 total/passed, zero failed, and zero skipped.
  The Stability result at
  `/tmp/potassium-provider-m1-stability/Logs/Test/Test-potassiumProvider-Stability-2026.09.08_23-40-14-+0200.xcresult`
  reports `result: Passed`, 327 total/passed, zero failed, and zero skipped:

  ```sh
  env -u INFOMANIAK_TOKEN -u ASC_ISSUER_ID -u ASC_KEY_ID -u ASC_KEY_NAME -u ASC_KEY_PATH -u ASC_TEAM_ID xcodebuild test -project potassiumProvider.xcodeproj -scheme potassiumProvider -configuration Debug -destination 'platform=macOS,arch=arm64' -enableCodeCoverage NO -only-testing:potassiumProviderTests -derivedDataPath /tmp/potassium-provider-m1-standard-rerun CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO COMPILER_INDEX_STORE_ENABLE=NO

  env -u INFOMANIAK_TOKEN -u ASC_ISSUER_ID -u ASC_KEY_ID -u ASC_KEY_NAME -u ASC_KEY_PATH -u ASC_TEAM_ID xcodebuild test -project potassiumProvider.xcodeproj -scheme potassiumProvider-Stability -configuration Stability -destination 'platform=macOS,arch=arm64' -enableCodeCoverage NO -derivedDataPath /tmp/potassium-provider-m1-stability CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO COMPILER_INDEX_STORE_ENABLE=NO
  ```

- The two shared app Test actions now persist `codeCoverageEnabled="NO"`; no
  coverage consumer exists in the repository. A follow-up unadorned full
  standard-scheme run (including UI) and unadorned profile runs reached their
  app-hosted test processes but this local Xcode host did not write a result
  bundle `Info.plist`. They were interrupted and are not recorded as passes.
  This is an environment limitation, not a test success or a File Provider
  behavior result. No credential, File Provider registration, Finder command,
  or remote mutation occurred in any attempt.

### 2026-08-31 — Milestone 1 review and repair

- `xcodebuild -list -project potassiumProvider.xcodeproj`: configuration and
  scheme discovery succeeded.
- `xcodebuild -showBuildSettings ... -configuration Stability`: confirmed
  `STABILITY`, production identity, app group, and entitlements.
- `xcodebuild test -quiet -project potassiumProvider.xcodeproj -scheme
  potassiumProvider-Stability -destination 'platform=macOS,arch=arm64'
  -only-testing:potassiumProviderTests/StabilityDiagnosticsTests`: thirteen
  focused tests passed after the adversarial findings were repaired. An earlier
  unsigned attempt could build but could not materialize the hosted macOS test
  worker; signed local execution succeeded.
- Adversarial findings fixed: compiled out the environment UI fixture, disabled
  legacy unified logs, added lifecycle locking and post-finish refusal,
  truncated interrupted tails, added owner-only/no-symlink/crash-sync file
  handling, bounded the active event file, matched zero-limit/tombstone/paging/
  statistics/observation/export behavior, and added a real child-process writer
  test. Two bounded final-scan turns were interrupted after the reviewer agent
  did not return; the earlier review's complete actionable list is resolved and
  the focused suite/privacy scan were rerun afterward.
- No live network or remote mutation was performed.

### 2026-08-31 — Milestone 2 review and repair

- Signed macOS `build-for-testing` passed for the Stability scheme, including
  Core, app, both extensions, and the unit bundle.
- The final credential-free `test-without-building` command exited normally
  with 27/27 selected executions successful: all diagnostic-span and operation-
  lifecycle tests across the Stability test-plan variants, plus exact lazy
  transfer, optional share-link, and concurrent transfer-start/cancel adapter
  tests. No live or default hosted suite was selected. Earlier focused runs
  encountered a local `DTServiceHub` logarchive-finalization hang after their
  result streams had completed; signing the refreshed hosted bundle allowed the
  final run and result bundle to close normally.
- Reviewer repairs rechecked lifecycle state after a suspended start append,
  moved terminal append attempts ahead of system callbacks, added stable span
  IDs, deduplicated progress buckets, instrumented transfer progress, classified
  File Provider recovery errors, rebound long-lived objects per active run,
  acknowledged materialization promptly after its callback span and kept the
  background work in correlated child spans, covered every SDK changed-field
  shape, separated enumerator lifecycle operations, and corrected cancellation,
  lazy-transfer, and expected-404 outcomes. The final pass also found and fixed
  the deferred-span reentrancy race, restored standard share-link unified spans,
  and made app activity storage resolve the active run dynamically.
- `git diff --check` and the added-line credential/private-URL scan passed.
- No live network or remote mutation was performed.

### 2026-09-01 — Milestone 3 Stability Lab

- Added a Stability-only macOS lab UI backed by the existing manual-token
  Keychain flow. Standard and Stability build identities register only their
  matching ordinary/lab domain purpose.
- Provisioning rejects any saved or registered domain and any external,
  unavailable, duplicate, or maintenance drive before remote mutation. It
  verifies the explicit drive root, creates one unique top-level directory,
  uploads a fixed marker with conflict-as-error, verifies it, persists root and
  marker IDs, and only then registers File Provider. Partial provisioning is
  retained for manual recovery; there is no automatic remote rollback.
- Reset requires an exact typed phrase and a complete bounded listing. The
  reset plan cannot represent root/marker/permanent deletion. Before every
  `trashItem`, the coordinator re-reads internal drive access, system domain
  registration, root, marker, and target parent and aborts on drift. A
  cross-process lifecycle lease blocks an active or newly starting diagnostics
  run for the entire reset. File Provider and action runtimes reject a domain
  purpose that does not match their compiled profile.
- `xcodebuild build-for-testing -quiet -project potassiumProvider.xcodeproj
  -scheme potassiumProvider-Stability -configuration Stability -destination
  'platform=macOS,arch=arm64' -derivedDataPath
  /tmp/potassium-provider-stability-lab-dd
  COMPILER_INDEX_STORE_ENABLE=NO` exited 0.
- The final signed `test-without-building`, restricted to
  `StabilityDiagnosticsTests`, `StabilityLabSafetyTests`, and
  `StabilityLabRemoteCoordinatorTests`, exited 0 with `TEST EXECUTE SUCCEEDED`:
  47 Swift Testing cases passed in three suites and the result bundle finalized
  at `/tmp/potassium-lab-final-v4-20260901.xcresult`. An earlier two-suite run had
  passed before local Xcode stalled during result-bundle finalization; the
  successful final run supersedes that incomplete result artifact.
- No live credential was read, no File Provider domain was registered, and no
  remote mutation was performed.

## Milestone 3 Decision Records

| Decision | Evidence | Live result | Chosen behavior | Tests | Truth-table impact |
| --- | --- | --- | --- | --- | --- |
| Domain/build isolation | shared production identity; File Provider registration map; plan invariant | not run | legacy records decode ordinary; app, File Provider, and action runtimes accept only the current profile's consistent purpose; live registration evidence is re-queried before provision/reset mutations | configuration profile tests; ordinary-domain no-call and domain-change race tests | adds fail-closed lab registration/cleanup row |
| Lab-root ownership | pinned client drive eligibility plus server-authoritative discovery/root/marker metadata | not run | treat discovery as internal membership only; prove lab ownership by this build's random marker plus exact persisted and remote root/marker identity under the explicit drive root | external-drive no-mutation, provision-shape, and marker mismatch tests | adds provisioning predicate without claiming product ownership |
| Ownership marker | plan requirement; remote upload/download and local configuration contracts | not run | marker payload has no name/path/account data; persist marker file ID separately; require local/remote marker equality and preserve the file | marker round-trip, missing/mismatch/parent/duplicate evidence tests | adds marker collision and preservation rows |
| Reset mutation | safe cleanup policy and truth-table trash/permanent-delete distinction | not run | exact confirmation, complete bounded pagination, preserve root/marker, fresh TOCTOU checks, trash only, live domain isolation, and a cross-process inactive-run lease | pagination/cursor, reset preservation, target/root/marker/domain drift, and run-lease tests | documents reversible trash and keeps unconditional permanent delete risk separate |

## Milestone 4 Decision Records

| Decision | Evidence | Live result | Chosen behavior | Tests | Truth-table impact |
| --- | --- | --- | --- | --- | --- |
| Command and credential boundary | plan invariant; existing manual-token Keychain flow | not run | command accepts preflight/run plus local stale-run recovery, permission prompting only where applicable, explicit `--yes-live`, and explicit `--yes-recover`; context loads the saved manual-token credential from Keychain and never accepts credential/account/root inputs; recovery reads no credential and performs no remote action | parser rejection, recovery dispatch, and closed console-status tests | no mutation semantic change |
| macOS permission preflight | Apple Accessibility trust and Apple Events target-permission APIs; File Provider registered/visible-domain APIs | not run | Accessibility, Finder Automation, File Provider registration, consent, and lab safety are typed preflights; the macOS Stability configuration alone carries Automation plus Finder-scoped sandbox Apple Events entitlements; OS consent and variable contextual UI return checkpoint exit 3, not product failure | pure permission/consent/checkpoint evaluator and build-setting/entitlements isolation tests | no conflict decision change |
| Scenario and assertion contract | plan's fixed scenario list; File Provider-visible root; typed remote adapter | not run | execute 16 steps in fixed order; a failure skips later steps while a typed UI checkpoint permits independent later scenarios; checkpoint reasons are restricted to their scenario; every passing step requires Finder-visible plus fresh server-authoritative assertions, correlated baseline/postcondition observations, and scenario-appropriate successful callback/network terminals; enumeration requires both item enumeration and anchor/change evidence; working-set requires a known same-run item and preserve-both requires two distinct Finder-visible candidates; restore/delete/cancel/contextual UI stop at checkpoints instead of substituting direct APIs, starting an unobserved transfer, or using global progress | report order, checkpoint classification, terminal-state, correlation, conjunctive enumeration/anchor evidence, missing/wrong-source diagnostic, round-trip, and immutable-evidence tests | observes mutation/conflict cells without redefining them |
| Finder evidence privacy and durability | Stability JSONL lifecycle and privacy boundary | not applicable | create an exclusive runner-owned run, publish a private per-step cross-process correlation pointer, replace closed assertion/API JSONL files, exclusive-create one immutable validated report as commit marker, verify caller summary counts against that report, then seal summary; on failure retain owner PID/token and the active unsealed bundle; explicit recovery requires a dead owner, writes immutable abandonment evidence, clears a stale step, and prevents ordinary finalization; store no identifiers, names, paths, URLs, bodies, headers, shares, or bytes in report evidence | prohibited-key/canary, duplicate/missing observation and diagnostic, summary mismatch, ownership exclusion, live/dead owner, stale-step abandonment, partial-write/retry, and one-write tests | diagnostics only |
| Live mutation scope | exact lab root/marker preflight and explicit operator confirmation | not run | live sequence is outside CI and operates only through the verified non-root lab; recheck sole saved/system domain, remote root/marker, and cached root URL's root-container/configured-domain binding before every scenario; immediately bind every existing-item mutation URL (and move destination) to its expected File Provider item and configured domain, reusing the single validated identifier for eviction; reset stays trash-only; restore and permanent deletion leave the lab root selected and never open global Trash or direct a destructive action; cancellation leaves an exact evicted item selected without starting a download; contextual actions never call the remote API directly | structural model, single-resolution item/domain drift, root/domain drift, and command safety tests; live validation remains operator-only | runner adds no permanent-delete mutation; `CR-013` remains open for the product callback |

## 2026-09-01 — Milestone 4 Finder runner

- Added the Stability-only macOS command and wrapper, Apple permission
  preflight, File Provider-visible scenario runner, closed 16-step report, and
  immutable assertion/API evidence assembly. No credential or private value is
  accepted on the command line or written to the evidence schema.
- The command exclusively owns its active run, uses a private per-step pointer
  for cross-process diagnostic correlation, and cannot seal a partial evidence
  assembly. Restore, permanent-delete, cancellation, and localized contextual
  UI terminate at explicit Finder/operator checkpoints rather than being
  represented by direct remote calls, an unobserved transfer, or domain-global
  progress.
- Failed/crashed commands retain ownership; explicit local recovery verifies
  the owner process is gone, writes an abandonment marker, removes a stale
  correlation pointer, and prevents ordinary summary finalization. Passing
  steps now require scenario-specific correlated terminal diagnostics;
  enumeration requires both listing and anchor/change terminals. Checkpoint
  reasons are scenario-bound, existing mutation URLs and the move destination
  are rebound to expected File Provider item/domain identities, eviction reuses
  its single validated identifier, the cached lab root is rebound after
  baseline pagination and immediately before execution, and summary sealing
  rejects aggregate counts that differ from the immutable report.
- The then-current signed Stability graph completed `build-for-testing`, including
  the Stability-only Automation and Finder-scoped sandbox Apple Events
  entitlements. All 33 selected Swift Testing cases reported passed in both
  scheme executions across three suites. That historical invocation did not
  finalize its result bundle. The finalized 2026-09-08 macOS Stability result
  above supersedes it with 327 passed and zero failures. The Stability
  app/extension graph also built successfully for a
  standard macOS Debug build, the iPhone 17 iOS 26.5 Simulator Stability build,
  and the generic visionOS Stability build after verifying all Finder-only
  sources are platform-gated. The final read-only adversarial review found no
  remaining code defect; its stale-evidence finding was closed by this current
  rebuild/run. No live credential was read, no Finder operation ran, and no
  remote mutation was performed during automated validation.

## 2026-09-01 — Milestone 5 API evidence and adapters

- Completed the operation-by-operation matrix against the potassiumChannel
  `0.3.0` pin, the captured official documentation revision, and pinned iOS,
  Android, and desktop sources. Reference client code was used only as behavior
  evidence; no GPL implementation was copied. Every live-result cell remains
  `not run` except the already-sanitized advanced-listing observation because
  no development credential or remote-mutation authority was provided.
- Corrected five discrepancies: modeled inherited share access and rejected
  unknown access values; explicitly encoded a cleared share expiration as JSON
  null while retaining the pinned typed route; rejected direct uploads above
  `1_000_000_000` bytes before callback buffering or request construction;
  mapped 408/429 to retryable
  server-unreachable recovery while retaining only safe parsed delta seconds;
  and sent an explicit extension-preserving duplicate name instead of `{}`.
- A fresh signed Stability `build-for-testing` completed successfully. The
  focused `test-without-building` selected `KDriveAPIEvidenceTests` and
  `KDriveContextActionTests`; all 17 unique cases passed in both scheme
  executions (34/34 reported successes). After the HTTP 429 precedence and
  fixture-literal repairs, the then-current seven-case API slice reported 14/14
  passes. After the pre-buffer repair, the final eight-case API slice reported
  all 16 passes across both scheme executions. That historical invocation did
  not finalize its result bundle; the finalized 2026-09-08 full Stability
  macOS result above supersedes it with 327 passed and zero failures.
- `git diff --check` and the credential/private-value scan were rerun after the
  final repairs. No live API request, File Provider mutation, or remote cleanup
  was performed.

## 2026-09-01 — Cross-platform completion validation

All commands removed the inherited Infomaniak and App Store Connect credential
variables. The four build commands exited successfully:

```sh
env -u INFOMANIAK_TOKEN -u ASC_ISSUER_ID -u ASC_KEY_ID -u ASC_KEY_NAME -u ASC_KEY_PATH -u ASC_TEAM_ID xcodebuild build-for-testing -quiet -project potassiumProvider.xcodeproj -scheme potassiumProvider-Stability -configuration Stability -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/potassium-final-macos COMPILER_INDEX_STORE_ENABLE=NO

env -u INFOMANIAK_TOKEN -u ASC_ISSUER_ID -u ASC_KEY_ID -u ASC_KEY_NAME -u ASC_KEY_PATH -u ASC_TEAM_ID xcodebuild build-for-testing -quiet -project potassiumProvider.xcodeproj -scheme potassiumProvider-Stability -configuration Stability -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17' -derivedDataPath /tmp/potassium-final-ios COMPILER_INDEX_STORE_ENABLE=NO

env -u INFOMANIAK_TOKEN -u ASC_ISSUER_ID -u ASC_KEY_ID -u ASC_KEY_NAME -u ASC_KEY_PATH -u ASC_TEAM_ID xcodebuild build -quiet -project potassiumProvider.xcodeproj -scheme potassiumProvider-Stability -configuration Stability -destination 'generic/platform=visionOS' -derivedDataPath /tmp/potassium-final-vision-device COMPILER_INDEX_STORE_ENABLE=NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO

env -u INFOMANIAK_TOKEN -u ASC_ISSUER_ID -u ASC_KEY_ID -u ASC_KEY_NAME -u ASC_KEY_PATH -u ASC_TEAM_ID xcodebuild build-for-testing -quiet -project potassiumProvider.xcodeproj -scheme potassiumProvider-Stability -configuration Stability -destination 'platform=visionOS Simulator,OS=26.5,name=Apple Vision Pro' -derivedDataPath /tmp/potassium-final-vision COMPILER_INDEX_STORE_ENABLE=NO
```

The full Swift unit-test target was then run without rebuilding on each hosted
destination. Output was filtered only for terminal test/error lines:

```sh
set -o pipefail
env -u INFOMANIAK_TOKEN -u ASC_ISSUER_ID -u ASC_KEY_ID -u ASC_KEY_NAME -u ASC_KEY_PATH -u ASC_TEAM_ID xcodebuild test-without-building -quiet -project potassiumProvider.xcodeproj -scheme potassiumProvider-Stability -configuration Stability -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/potassium-final-macos COMPILER_INDEX_STORE_ENABLE=NO -only-testing:potassiumProviderTests 2>&1 | rg --line-buffered "(Test case .* (passed|failed)|Test Suite|Testing started|error:|TEST EXECUTE|BUILD INTERRUPTED)"

set -o pipefail
env -u INFOMANIAK_TOKEN -u ASC_ISSUER_ID -u ASC_KEY_ID -u ASC_KEY_NAME -u ASC_KEY_PATH -u ASC_TEAM_ID xcodebuild test-without-building -quiet -project potassiumProvider.xcodeproj -scheme potassiumProvider-Stability -configuration Stability -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17' -derivedDataPath /tmp/potassium-final-ios COMPILER_INDEX_STORE_ENABLE=NO -only-testing:potassiumProviderTests 2>&1 | rg --line-buffered "(Test case .* (passed|failed)|Test Suite|Testing started|error:|TEST EXECUTE|BUILD INTERRUPTED)"

set -o pipefail
env -u INFOMANIAK_TOKEN -u ASC_ISSUER_ID -u ASC_KEY_ID -u ASC_KEY_NAME -u ASC_KEY_PATH -u ASC_TEAM_ID xcodebuild test-without-building -quiet -project potassiumProvider.xcodeproj -scheme potassiumProvider-Stability -configuration Stability -destination 'platform=visionOS Simulator,OS=26.5,name=Apple Vision Pro' -derivedDataPath /tmp/potassium-final-vision COMPILER_INDEX_STORE_ENABLE=NO -only-testing:potassiumProviderTests 2>&1 | rg --line-buffered "(Test case .* (passed|failed)|Test Suite|Testing started|error:|TEST EXECUTE|BUILD INTERRUPTED)"
```

At the time, the macOS, iOS Simulator, and visionOS Simulator unit-test process
emitted only passing terminal cases and no failure/error line, but their result
bundles did not finalize. The 2026-09-08 finalized macOS profile results above
supersede that incomplete macOS observation; iOS and visionOS have not been
rerun as part of this macOS reliability repair. Existing non-fatal Swift
Testing/Sendable warnings remain outside this stability-loop change. No live
credential was consumed, no Finder scenario ran, and no local or remote File
Provider mutation was performed.

A final scan of every added line in `codex/stability-loop-plan...HEAD` found one
credential-shaped literal in a newly added in-memory test fixture. It was
replaced with a per-execution UUID canary; the related Finder-command and Lab
remote-coordinator fixtures now contain no committed credential value, and the
injected remotes discard the canary without logging or persistence. The signed
macOS test graph rebuilt successfully and all 23 affected cases reported passed
in both scheme executions (46/46) before that historical result-finalization
issue. The finalized 2026-09-08 macOS profile results above are the current
macOS evidence. The reviewer returned PASS, and the repeated branch-range
added-literal scan found no nonempty credential or authorization-header fixture.

## API Decision Ledger

Evidence keys used by the per-operation matrix:

- **P** — the project-pinned OpenCow42 potassiumChannel `0.3.0`, peeled commit
  [`db829f1f`](https://github.com/OpenCow42/potassiumChannel/tree/db829f1f2bd8c2113a529c9c521bd5cdfb5ef4dc).
- **D** — [Infomaniak API reference](https://developer.infomaniak.com/docs/api)
  snapshot identified in Evidence Revisions. The public site exposes no source
  commit; each route was re-read from that captured page-data revision.
- **I** — official [iOS kDrive source](https://github.com/Infomaniak/ios-kDrive/tree/90c2e2560630b075b77b9e87b46b44d385a05283)
  at `90c2e256`; API fetchers and File Provider behavior were compared.
- **A** — official [Android kDrive source](https://github.com/Infomaniak/android-kDrive/tree/25e07993e87e8ae50f7c73aeaf4c6802eef1d434)
  at `25e07993`, including Core submodule `7037dab1`.
- **K** — official [desktop kDrive source](https://github.com/Infomaniak/desktop-kDrive/tree/f72372661e79744c243fd4963465aaae92a6eba7)
  at `f7237266`; network-job request shapes were compared.

Reference-client code is GPL behavioral evidence only. No implementation was
copied. `not run` means no development credential was supplied and therefore
no live request was sent. Dependency request tests at **P** cover unmodified
typed builders; app fixture names identify local adapter or policy coverage.

| Protocol operation | Version-pinned evidence and discrepancy | Live result | Chosen behavior | Affected tests | Truth-table impact |
| --- | --- | --- | --- | --- | --- |
| `listDrives()` | P typed core has no public discovery helper; I/A load eligible drive roles; public D does not expose `/2/drive/init` | not run | retain the small typed app request, accept one internal non-maintenance membership record, and never claim account ownership | `kdriveServiceLoadsDriveRolesFromDriveInitOnly`; Stability Lab external/duplicate/maintenance rejection | lab ownership rows remain fail closed |
| `item(driveID:fileID:)` | P/D/I/A/K agree on stable file ID metadata; ETag is an included resource | not run | request direct metadata with `with=etag`; treat it as authoritative before versioned mutations | mutation coordinator matching/stale-version suites | `C` remains stable ID plus ETag |
| `listDirectory(...)` | P/D/I/A expose per-folder cursor listing; ordinary listing accepts ETag | not run | request ETag first; retry without `with` only for the known 422 compatibility response | `kdriveServiceFallsBackToDirectoryListingWithoutETagAfter422` | no cursor protocol substitution |
| `listAdvancedDirectory(..., cursor:nil, ...)` | P supplies `/listing`; K uses drive-wide advanced listing; D currently has no public route page | prior sanitized observation only: `etag` and `files.etag` rejected; `files.capabilities` accepted | use `files.capabilities`; surface 422 and retain the prior snapshot/anchor | initial advanced-listing and 422 tests | advanced-listing row retained |
| `listAdvancedDirectory(..., cursor:value, ...)` | P supplies `/listing/continue`; K corroborates advanced cursors; D currently has no page | same prior sanitized observation | preserve advanced cursor/action semantics and never fall back to ordinary listing | continued advanced-listing and 422 tests | advanced-listing row retained |
| `listTrash(...)` | P/D/I/A expose cursor-paginated trash listing | not run | order and page through typed trash results; validate pagination before committing state | listing validator; trash enumeration coverage | no mutation change |
| `downloadFile(...)` | P/D/I/A/K agree on stable-ID download | not run | async convenience consumes the same lazy operation | lazy download fixture; transfer diagnostics tests | no conflict change |
| `downloadFileOperation(...)` | P exposes Foundation progress/cancel; I/K corroborate cancellable transfer work | not run | lazy start, one underlying cancellation, deduplicated progress, one terminal diagnostic | lazy transfer/progress/start-cancel tests | retry semantics unchanged |
| `thumbnail(...)` | P/D/I/A expose typed thumbnail size options | not run | use typed request; record only option shape | `kdriveServiceFetchesThumbnailThroughPotassiumRoute` | no mutation change |
| `uploadFile(...)` | P/D/I/A/K direct-upload contract; D says files over 1 GB require a session | not run | async convenience uses the guarded operation | upload request and direct-size boundary tests | adds large-upload fail-closed row |
| `uploadFileOperation(...)` | P encodes total size/conflict/token/hash; D caps direct upload at `1_000_000_000` bytes and documents sessions above it | not run | preflight callback-file size before loading, validate the loaded count again before request construction, and return a mapped synchronization error until a file-backed session adapter exists | upload shape; pure byte boundary; sparse-file pre-buffer rejection | `CR-017` mitigated |
| `replaceFile(...)` | P/D agree `file_id` plus `If-Match`; I/K corroborate conditional replacement | not run | async convenience performs the same guarded stable-ID replacement | conditional replace and race tests | conditional preserve-both rows unchanged |
| `replaceFileOperation(...)` | P/D support ETag condition and direct-upload limit | not run | validate size first; send stable ID, ETag, deterministic token/hash; preserve both on 409/412 | exact replace request; conditional-race tests; size boundary | `C`/409/412 and `CR-017` |
| `createDirectory(...)` | P/D/I/A/K expose parent-ID plus name creation | not run | typed create; recognized collisions receive one explicit conflict name | directory create/collision coordinator tests | directory-collision row unchanged |
| `renameItem(...)` | P/D/I/A/K use stable ID plus explicit name | not run | local same-field intent wins; recognized collision gets one conflict name | rename/refetch/idempotence/drift tests | rename rows unchanged |
| `moveItem(...)` | P/D/I/A/K use stable ID and destination; P supports `conflict=rename` and optional name | not run | merge move-only with remote rename; combined move/rename applies local name | move/rename concurrency suites | move rows unchanged |
| `updateModificationDate(...)` | P/D/I expose integer `last_modified_at` | not run | update only when it is the remaining requested field, then refetch | combined-field coordinator tests | combined-fields date row unchanged |
| `trashItem(...)` | P/D/I/A/K use stable ID and reversible trash | not run | local trash intent wins after requested content/metadata work | trash drift/concurrent-edit tests | reversible trash row unchanged |
| `deleteTrashedItem(...)` | P/D expose stable-ID delete; no source documents ETag/If-Match | not run | retain preflight/refetch rejection, but accepted request remains unconditional | permanent-delete matching/stale tests | `CR-013` remains open |
| `setFavorite(...)` | P/D/I/A expose separate favorite/unfavorite mutations; no conditional token | not run | mutate stable ID, then refetch authoritative metadata and invalidate both possible parents | `favoriteRefetchesMetadataAndInvalidatesBothParents` | adds favorite row |
| `duplicateItem(...)` | P allows an optional name and previously emitted `{}`; I/K always provide an explicit name; A uses copy-to-directory | not run | refetch source, derive an explicit extension-preserving `copy` name, send it, then refetch the created stable ID; never depend on server-selected naming | duplicate coordinator/name-policy and exact request-body tests | `CR-019` resolved |
| `trashedItem(...)` | P/D/I/A expose trashed metadata | not run | re-read the stable trashed item before choosing a restore parent | restore coordinator tests | adds restore row |
| `existingFileIDs(...)` | P/I/A expose batch existence checks | not run | verify the original restore parent, otherwise choose configured drive root | restore original/root fallback tests | adds restore row |
| `restoreTrashedItem(...)` | P/D/I/A use stable ID plus explicit destination | not run | restore to verified original parent or root fallback; never permanently delete | restore original/root failure tests | adds restore row |
| `shareLink(...)` | P/D/I/A expose `public`, `inherit`, and `password`; prior app decoder treated unknown rights as public | not run | decode all three known rights; expected 404 is optional success; unknown rights fail closed | optional-404, inherit decode, unknown-right tests | `CR-018` resolved |
| `createShareLink(...)` | P/D/I/A define known rights and capability fields | not run | validate password mode and encode the selected known right; diagnostics never retain URL/password | share defaults plus exact body tests | adds share-create row |
| `updateShareLink(...)` | D makes `valid_until` nullable; I/A explicitly clear with null; P 0.3.0 synthesized encoding omitted nil | not run | retain P's typed route/response but replace its body with an app adapter that explicitly encodes JSON null; unknown response rights fail closed | exact null/inherit body and response tests | `CR-018` resolved; `CR-021` open for no ETag |
| `deleteShareLink(...)` | P/D/I/A expose unconditional delete and no link-version condition | not run | disable by stable item ID; do not log/share the URL; document stale-editor race | contextual-action and diagnostic tests | adds share-delete row; `CR-021` open |
| `fileVersions(...)` | P/D/I expose page/per-page, descending creation order, and immutable version IDs | not run | use nondeprecated typed route and explicit paging | version-page model/action tests | adds version-list/restore evidence |
| `restoreFileVersion(...)` | P/D/I restore a selected version to an explicit destination/name | not run | always restore as a new copy and refetch its stable ID; current file is unchanged | version action/coordinator tests | adds restore-as-copy row |
| working-set listings | P typed latest/favorite/shared routes; I/A/K corroborate working-set categories | not run | bounded deduplicated union; never infer success from root existence alone | `WorkingSetSyncTests`; Finder working-set assertion tests | no mutation change |
| `listPartialActivities(...)` | P typed `/listing/partial`; D currently has no public page; I/K corroborate change feeds | not run | batch 200 stable IDs; advance watermark only after a validated complete response | partial-activity and failed-poll tests | cursor/anchor fail-closed rows unchanged |
| HTTP rejection mapping | D documents a global 60 requests/minute limit; P retains raw Retry-After metadata | not run | map 408/429 to retryable `.serverUnreachable`; retain only a parsed nonnegative delta-seconds integer, never the raw header/body; other 4xx remain deliberate | table-driven 408/429/507/5xx classifier tests | adds retry mapping row; `CR-020` mitigated |

### Accepted discrepancy corrections

1. Added `inherit` and changed unknown share access from a widening `.public`
   fallback to a typed failure.
2. Added an app-owned update body that explicitly sends `valid_until: null`
   while retaining potassiumChannel's pinned method, path, response, and client.
3. Rejected direct create and replacement callback files above one billion
   bytes before buffering, then rechecked the loaded count before constructing
   an upload operation. Session uploads remain a documented implementation gap;
   the callback source stays File Provider-owned but this early path creates no
   separate conflict-stage copy.
4. Changed HTTP 408 and 429 recovery to `.serverUnreachable` and retained only
   parsed delta seconds from Retry-After.
5. Changed duplicate-in-place to send an explicit derived name instead of an
   empty options body.

The advanced-listing and `/2/drive/init` routes remain client/live-evidence
adapters because the public documentation snapshot does not contain them.
Permanent trash deletion and share update/delete remain marked unconditional;
no conditional primitive is invented without authoritative evidence.
