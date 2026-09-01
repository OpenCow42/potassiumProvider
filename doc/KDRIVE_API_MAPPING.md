# kDrive API Mapping

The app talks to kDrive through `PotassiumKDriveService`, which implements the
local `KDriveFileProviding` protocol. `PotassiumKDriveService` wraps
potassiumChannel's typed `KDriveService` and request builders.

Action-only operations are separated behind `KDriveContextActionProviding` so
the existing File Provider mutation protocol remains unchanged.

The version-pinned comparison sources, live-result status, adapter decisions,
tests, and truth-table impact are maintained in
[`STABILITY_LOOP_AUDIT.md`](STABILITY_LOOP_AUDIT.md). The current dependency is
potassiumChannel 0.3.0 at
`db829f1f2bd8c2113a529c9c521bd5cdfb5ef4dc`; GPL client implementations are
behavioral evidence only and are not copied.

In the Stability profile, every operation below also emits a closed-enum
diagnostic span with its route template and option shape. Callback TaskLocal
correlation is inherited by nested requests; no raw URL, identifier, query
value, header, body, name, path, or file bytes enter the diagnostic record.
Lazy transfer spans begin only when their operation is consumed or cancelled.
Expected share-link absence (`404`) completes successfully, while cancellation
uses the closed cancelled phase instead of a failure record.

## Operation Map

| Provider operation | Local method | potassiumChannel call | Visible endpoint |
| --- | --- | --- | --- |
| Load usable internal drives | `listDrives()` | raw `APIRequest` through `driveClient` | `GET /2/drive/init?with=drives` |
| Item metadata | `item(driveID:fileID:)` | `getFile` | `GET /3/drive/{driveId}/files/{fileId}` |
| Legacy folder listing | `listDirectory(...)` | `listDirectoryFiles` | `GET /3/drive/{driveId}/files/{fileId}/files` |
| Advanced folder listing | `listAdvancedDirectory(..., cursor: nil, ...)` | `listAdvancedDirectoryListing` | `GET /3/drive/{driveId}/files/{fileId}/listing` |
| Advanced listing continuation | `listAdvancedDirectory(..., cursor: value, ...)` | `continueAdvancedDirectoryListing` | `GET /3/drive/{driveId}/files/{fileId}/listing/continue` |
| Trash listing | `listTrash(...)` | `listTrashFiles` | `GET /3/drive/{driveId}/trash` |
| Latest working-set items | `listWorkingSetRelevantItems(...)` | `listLastModifiedFiles` | `GET /3/drive/{driveId}/files/last_modified` |
| Favorite working-set items | `listWorkingSetRelevantItems(...)` | `listFavoriteFiles` | `GET /3/drive/{driveId}/files/favorites` |
| Shared working-set items | `listWorkingSetRelevantItems(...)` | `listMySharedFiles` and `listSharedWithMeFiles` | `GET /3/drive/{driveId}/files/my_shared`, `GET /3/drive/{driveId}/files/shared_with_me` |
| Relevant item activity | `listPartialActivities(...)` | `listPartialFileActivities` | `POST /3/drive/{driveId}/files/listing/partial` |
| Download | `downloadFileOperation(...)` | `downloadFile` operation | `GET /2/drive/{driveId}/files/{fileId}/download` |
| Thumbnail | `thumbnail(...)` | `getFileThumbnail` | `GET /2/drive/{driveId}/files/{fileId}/thumbnail` |
| Create/upload file | `uploadFileOperation(...)` | `uploadFile` operation | `POST /3/drive/{driveId}/upload` |
| Replace file contents | `replaceFileOperation(...)` | `uploadFile` operation | `POST /3/drive/{driveId}/upload` |
| Create directory | `createDirectory(...)` | `createDirectory` | `POST /3/drive/{driveId}/files/{fileId}/directory` |
| Rename | `renameItem(...)` | `renameFile` | `POST /2/drive/{driveId}/files/{fileId}/rename` |
| Move | `moveItem(...)` | `moveFile` | `POST /3/drive/{driveId}/files/{fileId}/move/{destinationDirectoryId}` |
| Trash | `trashItem(...)` | `trashFileV2` | `DELETE /2/drive/{driveId}/files/{fileId}` |
| Permanently delete trashed item | `deleteTrashedItem(...)` | `removeTrashedFile` | `DELETE /2/drive/{driveId}/trash/{fileId}` |
| Favorite/unfavorite | `setFavorite(...)` | `favoriteFile` / `unfavoriteFile` | typed kDrive favorite endpoints |
| Duplicate in place | `duplicateItem(...)` | `duplicateFile` | `POST /3/drive/{driveId}/files/{fileId}/duplicate` |
| Read trashed metadata | `trashedItem(...)` | `getTrashedFile` | typed kDrive trash metadata endpoint |
| Check restore parent | `existingFileIDs(...)` | `checkFilesExistence` | typed kDrive existence endpoint |
| Restore from trash | `restoreTrashedItem(...)` | `restoreTrashedFile` | typed kDrive trash restore endpoint |
| Read share link | `shareLink(...)` | `getFileShareLink` | `GET /2/drive/{driveId}/files/{fileId}/link` |
| Create share link | `createShareLink(...)` | `createFileShareLink` | `POST /2/drive/{driveId}/files/{fileId}/link` |
| Update share link | `updateShareLink(...)` | `updateFileShareLink` | `PUT /2/drive/{driveId}/files/{fileId}/link` |
| Disable share link | `deleteShareLink(...)` | `deleteFileShareLink` | `DELETE /2/drive/{driveId}/files/{fileId}/link` |
| List versions | `fileVersions(...)` | nondeprecated `listFileVersions` | `GET /3/drive/{driveId}/files/{fileId}/versions` |
| Restore version as copy | `restoreFileVersion(...)` | `restoreFileVersionToDirectory` | `POST /3/drive/{driveId}/files/{fileId}/versions/{versionId}/restore/{destinationDirectoryId}` |

Some mutation endpoint paths are abstracted behind potassiumChannel service
methods in this app. The table names the local operation and service call so the
implementation can be followed even when the request body is built by the
library.

## Drive Eligibility

`listDrives()` loads the authenticated user's drive response directly from the
kDrive API. The setup model follows the official iOS kDrive eligibility rule:
a drive is usable when its `role` is neither `none` nor `external`. Admin and
ordinary internal-user roles are therefore eligible, while unavailable drives
and external shared drives are excluded from new File Provider domains.

Drive discovery does not call the general `GET /1/account` API and does not
claim to prove product ownership. Stored File Provider domains remain visible
for recovery when a later discovery response no longer includes an eligible
drive.

The Stability Lab applies a stricter access gate before any remote mutation:
exactly one discovery record must match the selected drive, its role must be
internal, and it must not be in maintenance. This is internal membership, not
an account-ownership claim. Provisioning then verifies
the explicit drive-root metadata, creates one direct child, uploads a marker
with `conflict=error`, and re-reads the root and marker. Reset fully paginates
ordinary listing and uses only `trashItem`; it re-reads ownership evidence and
each target's parent immediately before every trash request. Lab reset never
calls `deleteTrashedItem` and never removes its root or marker.
The locally persisted random marker plus exact remote root/marker identity is
the Stability Lab ownership proof.

The separately invoked Finder Stability run never calls `deleteTrashedItem`
directly. After `--yes-live` and the same exact lab/marker preflight, its restore
and permanent-delete scenarios retain the verified lab-root selection and emit
typed operator checkpoints without opening the user-global Trash or directing
a destructive action. This avoids both an irreversible, unconditional remote
request and presenting unrelated Trash contents as lab-scoped UI. `CR-013` remains
open for the product's existing permanent-delete callback; the runner does not
claim to automate that unresolved risk, and CI/preflight never runs the live
sequence.

Binary operations are exposed to File Provider as `KDriveTransferOperation`.
It preserves potassiumChannel's live Foundation progress, shared async result,
and cancellation of the underlying URL session task. Async convenience methods
remain available for callers that do not need to observe the transfer.

## Listing Options

Legacy directory listing uses:

- cursor from Apple page data
- limit `200`
- order by `name` ascending
- retries without an included resource if the ETag-enabled request returns HTTP
  422

Advanced directory listing uses:

- limit `200`
- order by `type`, then `name`
- per-field ascending order for `type` and `name`
- `with=files.capabilities`, matching the open-source desktop kDrive client
- HTTP 422 is surfaced to File Provider as `.cannotSynchronize`; it does not
  fall back to ordinary directory listing because that route has neither
  advanced change actions nor compatible cursor semantics

Trash listing uses:

- cursor from Apple page data
- limit `200`
- order by `name` ascending

## Upload Options

File create uses `UploadKDriveFileOptions` with:

- `conflict: "rename"` in the production mutation coordinator, preserving the
  server-created item when a name collision exists
- `directoryId: parentID`
- `fileName`
- optional `lastModifiedAt`
- deterministic `clientToken`, SHA-256 `totalChunkHash`, and `with=etag`

File replace uses `UploadKDriveFileOptions` with:

- stable `fileId`
- required `If-Match` ETag
- deterministic `clientToken`, SHA-256 `totalChunkHash`, and `with=etag`
- optional `lastModifiedAt`
- no create-conflict option, directory ID, or filename

Move uses `MoveKDriveFileOptions` with:

- `conflict: "rename"`
- optional new name when move and rename happen together

Directory create does not currently pass an explicit conflict policy.

## Advanced Listing Response Mapping

`listAdvancedDirectory(...)` maps potassiumChannel's
`KDriveAdvancedDirectoryListing` to `KDriveAdvancedItemPage`:

- `data.files` becomes `items`
- `data.actionsNewestFirst` becomes `KDriveRemoteFileAction`, so the newest
  effective state wins when the reducer keeps its first action per item
- `data.actionsFiles` becomes `actionItems`
- response cursor becomes `nextCursor`
- response `hasMore` becomes `hasMore`

`KDriveRemoteErrorClassifier.isInvalidCursor(...)` detects invalid advanced
listing cursors from `APIClientError.unacceptableStatusCode` bodies containing
both "invalid" and "cursor".

The partial-activity request is batched at 200 identifiers and uses the last
durable successful-poll watermark. It includes create, delete, trash, restore,
update, rename, move, favorite, and share actions relevant to working-set state.

## Opaque vault mapping

Encrypted domains use only random-container create/list, file-backed ciphertext
upload/download, and physical ciphertext deletion. Upload fields contain a
random `.bin` name, random client token, conflict-as-error, numeric container
ID, byte count, and `application/octet-stream`. Logical names, paths, MIME
types, dates, hashes, device names, favorites, shares, and versions are never
sent through this boundary. Latest/favorite/shared/activity/preview/thumbnail
endpoints are not called for encrypted items.
