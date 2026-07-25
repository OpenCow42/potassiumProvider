# kDrive API Mapping

The app talks to kDrive through `PotassiumKDriveService`, which implements the
local `KDriveFileProviding` protocol. `PotassiumKDriveService` wraps
potassiumChannel's typed `KDriveService` and request builders.

Action-only operations are separated behind `KDriveContextActionProviding` so
the existing File Provider mutation protocol remains unchanged.

## Operation Map

| Provider operation | Local method | potassiumChannel call | Visible endpoint |
| --- | --- | --- | --- |
| Load drives | `listDrives()` | raw `APIRequest` through `driveClient` | `GET /2/drive/init?with=drives` |
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
