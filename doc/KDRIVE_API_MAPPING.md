# kDrive API Mapping

The app talks to kDrive through `PotassiumKDriveService`, which implements the
local `KDriveFileProviding` protocol. `PotassiumKDriveService` wraps
potassiumChannel's typed `KDriveService` and request builders.

## Operation Map

| Provider operation | Local method | potassiumChannel call | Visible endpoint |
| --- | --- | --- | --- |
| Load drives | `listDrives()` | raw `APIRequest` through `driveClient` | `GET /2/drive/init?with=drives` |
| Item metadata | `item(driveID:fileID:)` | `getFile` | `GET /3/drive/{driveId}/files/{fileId}` |
| Legacy folder listing | `listDirectory(...)` | `listDirectoryFiles` | `GET /3/drive/{driveId}/files/{fileId}/files` |
| Advanced folder listing | `listAdvancedDirectory(..., cursor: nil, ...)` | `listAdvancedDirectoryListing` | `GET /3/drive/{driveId}/files/{fileId}/listing` |
| Advanced listing continuation | `listAdvancedDirectory(..., cursor: value, ...)` | `continueAdvancedDirectoryListing` | `GET /3/drive/{driveId}/files/{fileId}/listing/continue` |
| Trash listing | `listTrash(...)` | `listTrashFiles` | `GET /3/drive/{driveId}/trash` |
| Download | `downloadFileOperation(...)` | `downloadFile` operation | `GET /2/drive/{driveId}/files/{fileId}/download` |
| Thumbnail | `thumbnail(...)` | `getFileThumbnail` | `GET /2/drive/{driveId}/files/{fileId}/thumbnail` |
| Create/upload file | `uploadFileOperation(...)` | `uploadFile` operation | `POST /3/drive/{driveId}/upload` |
| Replace file contents | `replaceFileOperation(...)` | `uploadFile` operation | `POST /3/drive/{driveId}/upload` |
| Create directory | `createDirectory(...)` | `createDirectory` | `POST /3/drive/{driveId}/files/{fileId}/directory` |
| Rename | `renameItem(...)` | `renameFile` | `POST /2/drive/{driveId}/files/{fileId}/rename` |
| Move | `moveItem(...)` | `moveFile` | `POST /3/drive/{driveId}/files/{fileId}/move/{destinationDirectoryId}` |
| Trash | `trashItem(...)` | `trashFileV2` | `DELETE /2/drive/{driveId}/files/{fileId}` |
| Permanently delete trashed item | `deleteTrashedItem(...)` | `removeTrashedFile` | `DELETE /2/drive/{driveId}/trash/{fileId}` |

Some mutation endpoint paths are abstracted behind potassiumChannel service
methods in this app. The table names the local operation and service call so the
implementation can be followed even when the request body is built by the
library.

Binary operations are exposed to File Provider as `KDriveTransferOperation`.
It preserves potassiumChannel's live Foundation progress, shared async result,
and cancellation of the underlying URL session task. Async convenience methods
remain available for callers that do not need to observe the transfer.

## Listing Options

Legacy directory listing uses:

- cursor from Apple page data
- limit `200`
- order by `name` ascending

Advanced directory listing uses:

- limit `200`
- order by `type`, then `name`
- per-field ascending order for `type` and `name`
- potassiumChannel's minimal advanced-listing included resources

Trash listing uses:

- cursor from Apple page data
- limit `200`
- order by `name` ascending

## Upload Options

File create uses `UploadKDriveFileOptions` with:

- `conflict: "version"`
- `directoryId: parentID`
- `fileName`
- optional `lastModifiedAt`

File replace uses `UploadKDriveFileOptions` with:

- `conflict: "version"`
- `fileId`
- optional `lastModifiedAt`

Move uses `MoveKDriveFileOptions` with:

- `conflict: "rename"`
- optional new name when move and rename happen together

Directory create does not currently pass an explicit conflict policy.

## Advanced Listing Response Mapping

`listAdvancedDirectory(...)` maps potassiumChannel's
`KDriveAdvancedDirectoryListing` to `KDriveAdvancedItemPage`:

- `data.files` becomes `items`
- `data.actions` becomes `KDriveRemoteFileAction`
- `data.actionsFiles` becomes `actionItems`
- response cursor becomes `nextCursor`
- response `hasMore` becomes `hasMore`

`KDriveRemoteErrorClassifier.isInvalidCursor(...)` detects invalid advanced
listing cursors from `APIClientError.unacceptableStatusCode` bodies containing
both "invalid" and "cursor".

## Unused Available API

potassiumChannel also exposes `/files/listing/partial`, but this app does not
use it today.
