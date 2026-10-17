# Destructive actions and their tests

Every way Strata deletes, trashes, moves, renames, overwrites, evicts, or changes the permissions or metadata of
files, on this Mac, on a server, in a container's copy, or in its own stores, with the code that does it and the tests
that cover it (`TestFile/test`, under `Tests/StrataTests`). Each test was checked by breaking the rule it guards and
watching it fail. A change to any of these, or a new one, comes with tests and a row here (see AGENTS.md).

## Delete and the Trash

| Action | Code | Tests |
|---|---|---|
| Move to Trash (⌘⌫, menus, every view) | `BrowserViewController.moveToTrash`, `FileOps.trashInBackground`, `FileOps.canTrash` | `TrashUndoTests/onlyTheSelectionGoesAndUndoPutsItBack`, `aLinkGoesToTheTrashNotWhatItPointsTo`; `DeleteScopeTests/aTrashIsNeverTrashedOrDeletedItself`; `SelectionTargetsTests/*` |
| Delete Immediately (⌥⌘⌫) | `deletionPlan`, `deleteAll` | `DeleteTests/*` (selection only, nested, links, odd names, disks, unchangeable folders, locked, already gone); `DeleteScopeTests/aTrashIsNeverTrashedOrDeletedItself` |
| Empty Trash | `Trash.empty`, `Trash.folders` | `DeleteTests/emptyingATrashDeletesWhatsInItAndNothingElse`, `aTrashThatIsALinkIsNeverFollowed`, `aLockedItemInTheTrashIsReportedAndTheRestGo`; `DeleteScopeTests/emptyTrashOnlyEverEmptiesTrashFolders`, `noOtherFolderCountsAsATrash` |
| Put Back | `putBack`, `Trash.location`, `FileOps.removeEmptyFolders` | `PutBackTests/*`; `TrashUndoTests/onlyEmptyFoldersGoWhenTheirItemsDo`, `undoingAPutBackRemovesOnlyTheFoldersItMadeOnceEmpty` |
| Drop on the sidebar's Trash | `SidebarViewController.canTrash` | `DropTests/theSidebarsTrashTakesOnlyWhatCanBeTrashed` |

## Undo and History

| Action | Code | Tests |
|---|---|---|
| ⌘Z / ⇧⌘Z of moves, renames, Move to Trash | `FileOps.registerMoveUndo`, `FileOps.Landed` | `TrashUndoTests/undoingARenameLeavesAFileSwappedInSince`, `undoAndRedoPressedAtOnceHappenInOrder`, `undoingTwoOperationsAtOnceUndoesBoth`; `AcrossDisksTests/aRenameAcrossDisksUndoesAndRedoes` |
| ⌘Z / ⇧⌘Z of copies, duplicates, move jobs | `TransferUndo.register`, `TransferUndo.perform`, `TransferJob.landed` | `TrashUndoTests/undoingACopyTrashesOnlyItsOwnCopies`, `undoingAMoveJobMovesBackOnlyItsOwnItems`; `TransferTests/undoingACopyLeavesAFileSwappedInWhileTheJobRan`; `AcrossDisksTests/aMoveJobAcrossDisksUndoesAndRedoesOnlyItsOwnItems`, `undoAndRedoPressedAtOnceAcrossDisksBothHappenInOrder` |
| ⌘Z of New Folder / New File | `FileOps.registerTrashUndo` | `TrashUndoTests/undoingANewFolderLeavesOneMadeInItsPlace` |
| Undo from History | `OperationLog.undo`, `holdsOriginal` | `TrashUndoTests/historyUndoBringsBackWhatWasTrashedAndOnlyThat`, `undoLeavesAloneWhatTookTheOldPlace`, `undoNeverMovesBackAnItemThatWasSwappedForAnother`, `undoMovesBackOnlyTheMovedItems` |

## Copy, move, drop, paste

| Action | Code | Tests |
|---|---|---|
| Copy / move items (engine) | `TransferEngine.perform`, replace, merge, verify | `TransferTests/*` |
| Copy / move jobs (drag and drop, paste, other pane, Duplicate) | `TransferQueue.enqueue`, `TransferJob` | `TransferJobTests/*`, incl. `aReadOnlyCopyTakesNothingAndWhatLeavesItIsCopied` |
| What a drop does | `FileDrop.operation(_:into:mask:option:)` | `DropTests/*` |
| Cut and paste | `Clipboard`, `pasteItems` | `ClipboardTests/*` |

## Rename and new items

| Action | Code | Tests |
|---|---|---|
| Rename (inline, click to rename, Rename menu) | `FileOps.rename` | `InlineRenameTests/*`; `RenameTests/*` |
| Batch rename, swaps and chains | `RenameRules`, `FileOps.moveAll` | `RenameTests/*` |
| New Folder / New File | `FileOps.newFolder`, `newFile` | `NewFileTests/*`; `TrashUndoTests/undoingANewFolderLeavesOneMadeInItsPlace` |

## Metadata

| Action | Code | Tests |
|---|---|---|
| Locked, permissions, comments (Get Info) | `FileInfoEditing` | `MetadataEditTests/lockingTouchesOnlyThatItem`, `permissionsChangeOnlyThatAccessOnThatItem`, `aCommentChangesOnlyTheComment` |
| Tags | `TagStore.update`, `toggle`, `canTag` | `MetadataEditTests/tagsGoOnTheChosenFilesOnly` |

## Compare and Sync, archives, Ask Strata, project cleanup

| Action | Code | Tests |
|---|---|---|
| Sync (copies and extras to the Trash) | `FolderCompare.defaultAction`, `syncPlan` | `FolderSyncTests/*` |
| Compress | `Archiver.compress`, `place` | `MetadataEditTests/compressingAddsOneArchiveAndNeverReplacesOne`, `aLinkIsArchivedAsALink` |
| Extract | `Archiver.extract*` | `ArchiveSafetyTests/*` |
| Ask Strata plans (rename, move, trash, new folders), their undo and redo | `PlanValidator`, `PlanExecutor`, `PlanTransaction` | `PlanSafetyTests/*` |
| Project cleanup | `ProjectCleanup` | `ProjectCleanupTests/*` |

## Servers (SFTP, S3)

| Action | Code | Tests |
|---|---|---|
| Delete, move, rename, new items on a server | `RemoteFiles`, `SFTPBackend` | `ServerSafetyTests/*`; `RemoteFilesTests/newFilesAreMadeOnTheServerNeverOverAnything`, `deletingALinkLeavesWhatItPointsTo`; `SFTPClientTests/foldersRenamesAndRemoval` |
| Upload (asks before replacing) | `copyToServer`, `uploadChoice`, `RemoteFiles.upload` | `ServerSafetyTests/copyingOntoTakenNamesAsksOrLeavesThem`; `RemoteFilesTests/uploadsFilesAndFolders`, `uploadingOverALinkReplacesTheLink` |
| S3 delete, rename, upload | `S3Backend` | `DeleteScopeTests` (S3Tests extension): `deletingAFolderTakesOnlyTheKeysInIt`, `deletingAFileTakesOnlyThatKey`, `theBucketItselfIsNeverDeleted`, `renamingAFolderMovesExactlyItsKeys`, `renamingOnS3NeverReplacesAnything`, `aCopyThatFailsLeavesTheOriginal`, `uploadsAndFoldersNeverTakeTheBucketsTop`, `whatsTakenIsSeenBeforeCopyingOntoIt` |
| Copying out of a server's copy | `ContainerCopies.finishCopyingOut`, `LazyCopies.stageForClipboard` | `RemoteFilesTests/copiedOutLinksLeadingOutsideAreDropped`, `mergingOutLeavesWhatWasThereAlone`, `theClipboardGetsAFinishedCopy` |

## Containers

| Action | Code | Tests |
|---|---|---|
| Writing a container's files into its copy | `CopyWriter.writeTree`, listings | `ContainerCopyTests/aContainersFolderIsWrittenOnlyIntoItsCopy`, `aCopyThatIsALinkIsNotWrittenThrough`; `ContainerTests/listingsAreWrittenWithoutEscapingTheFolder`, `linksAlwaysResolveInsideTheCopy` |
| Fetching one file | `CopyWriter.fetchFile` | `ContainerCopyTests/aFetchedFileTakesOnlyItsPlaceholdersPlace`, `aFetchThatIsntAFileOrFindsSomethingElseChangesNothing` |
| Containers' and projects' folders | `CopyWriter.syncContainers` | `ContainerTests/theContainersFolderFollowsTheEngine`, `composeProjectsGroupTheirContainers`, `aLeftoverFolderNamedLikeAProjectMakesWay`, `projectsNamedAlikeShareAFolder`, `aContainerCalledLikeAProjectKeepsItsFiles` |
| Dragging out of a container | `ContainerPromises` | `ContainerCopyTests/aDraggedOutItemNeverReplacesWhatsAtTheDrop` |
| Start, stop, restart, pause | `ContainerAPI.perform` | `ContainerTests/actionsAreOnePostEach` |

## iCloud and File Provider

| Action | Code | Tests |
|---|---|---|
| Remove Download | `CloudActions.removable`, `removeDownload` | `DeleteScopeTests/removeDownloadFreesOnlyWhatsAlsoInTheCloud` |

## The `strata` command, Strata's own data

| Action | Code | Tests |
|---|---|---|
| Installing the command | `CommandLineTool.mayReplace` | `DeleteScopeTests/theCommandReplacesOnlyItsOwnLink` |
| Archives' copies (remove, replace, prune) | `ArchiveCache`, `Archiver.removeTree` | `CacheRemovalTests/aCopyIsRemovedOnlyAsAWholeEntryOfTheCache`, `aNewCopyReplacesOnlyOlderCopiesOfTheSameArchive`, `pruningTakesOnlyStaleCopies`, `removingATreeNeverFollowsALinkOut` |
| Containers' and servers' copies (remove, set aside at quit) | `ContainerCopies.remove`, `RemoteCopies.remove`, `setAsideForRemoval`, `removeSetAside` | `CacheRemovalTests/aContainersOwnFilesAreNeverRemovedAsAFolder`, `settingCopiesAsideRemovesOnlyThemAtQuit` |
| Stores (History, index), content index reset, script files | `SecureStorage.write`, `SemanticIndex.reset`, `ProjectActions.removeStaleCommandFiles` | `CacheRemovalTests/savingAStoreReplacesOnlyItsOwnFile`, `resettingTheContentIndexRemovesOnlyItsStore`, `staleScriptFilesGoOnlyFromTheirFolder` |
| Tests never touch your data | `SecureStorage.isTestRun`, `caches` | `DeleteTests/testRunsKeepHistoryAndIndexesOutOfYourOwn`; `DeleteScopeTests/testsKeepToCachesOfTheirOwn` |

## What tests can't reach

- **Real iCloud eviction.** It needs a signed-in iCloud account. What's chosen is tested, and so is macOS refusing to
  evict a file, folder or link that isn't in the cloud.
- **An item swapped in at the very moment it lands.** Closed by design rather than timed in a test: an item is
  expected where it goes before a move on one disk starts, and recorded as it lands otherwise. Undo and redo pressed
  quickly are tested: each waits for the one before.
- **Alerts and sheets.** What they decide is a plain function, and that function is tested (`deletionPlan`,
  `uploadChoice`, `FolderCompare.syncPlan`, `CommandLineTool.mayReplace`).
