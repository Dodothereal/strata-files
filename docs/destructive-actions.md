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
| ⌘Z / ⇧⌘Z of copies, duplicates, move jobs | `TransferUndo.register`, `TransferUndo.perform`, `TransferJob.landed` | `TrashUndoTests/undoingACopyTrashesOnlyItsOwnCopies`, `undoingAMoveJobMovesBackOnlyItsOwnItems`; `TransferTests/undoingACopyLeavesAFileSwappedInWhileTheJobRan`, `aFileSwappedTheMomentItLandsIsNeverUndone`, `aRenamedFileSwappedTheMomentItLandsIsNeverUndone`; `AcrossDisksTests/aMoveJobAcrossDisksUndoesAndRedoesOnlyItsOwnItems`, `undoAndRedoPressedAtOnceAcrossDisksBothHappenInOrder`, `aFileSwappedTheMomentItLandsAcrossDisksIsNeverUndone` |
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
| Remove Download | `CloudActions.removable`, `removeDownload` (the system's evict injected) | `DeleteScopeTests/removeDownloadFreesOnlyWhatsAlsoInTheCloud`, `removeDownloadAsksToFreeExactlyTheItemsChosen` |

## The `strata` command, Strata's own data

| Action | Code | Tests |
|---|---|---|
| Installing the command | `CommandLineTool.mayReplace` | `DeleteScopeTests/theCommandReplacesOnlyItsOwnLink` |
| Archives' copies (remove, replace, prune) | `ArchiveCache`, `Archiver.removeTree` | `CacheRemovalTests/aCopyIsRemovedOnlyAsAWholeEntryOfTheCache`, `aNewCopyReplacesOnlyOlderCopiesOfTheSameArchive`, `pruningTakesOnlyStaleCopies`, `removingATreeNeverFollowsALinkOut` |
| Containers' and servers' copies (remove, set aside at quit) | `ContainerCopies.remove`, `RemoteCopies.remove`, `setAsideForRemoval`, `removeSetAside` | `CacheRemovalTests/aContainersOwnFilesAreNeverRemovedAsAFolder`, `settingCopiesAsideRemovesOnlyThemAtQuit` |
| Stores (History, index), content index reset, script files | `SecureStorage.write`, `SemanticIndex.reset`, `ProjectActions.removeStaleCommandFiles` | `CacheRemovalTests/savingAStoreReplacesOnlyItsOwnFile`, `resettingTheContentIndexRemovesOnlyItsStore`, `staleScriptFilesGoOnlyFromTheirFolder` |
| Tests never touch your data | `SecureStorage.isTestRun`, `caches` | `DeleteTests/testRunsKeepHistoryAndIndexesOutOfYourOwn`; `DeleteScopeTests/testsKeepToCachesOfTheirOwn` |

## Where the system is stood in for

- **iCloud eviction.** `evictUbiquitousItem` needs a signed-in account, so `CloudActions.removeDownload` takes the
  evict call and the test records exactly which items it's asked to free, in which order, and that it goes on past a
  refusal. What macOS does with an item not in the cloud is tested too: it refuses, and the item stays.
- **The moment an item lands.** `TransferEngine.hooks.afterLanding` is called the instant an item has been placed
  and recorded for undo, before anything else happens to it. Tests swap the file right then, for a copy, a rename
  and a move across disks, and show the undo leaves the swapped file alone. (A move across disks keeps its original
  too: the copy no longer matches it.)
- **Alerts and sheets.** What they decide is a plain function, and that function is tested (`deletionPlan`,
  `uploadChoice`, `FolderCompare.syncPlan`, `CommandLineTool.mayReplace`).
- **Disks.** Moves across disks run against a disk image each test attaches and detaches (`ScratchVolume`). Ejecting
  a disk (`Places.eject`, the sidebar's and the menu's Eject) only hands the volume to macOS; nothing of the user's
  changes, and it isn't tested.

## Every function, by file

What the audit found (`scripts/audit-destructive.py` lists each function in `Sources/` holding a call that can delete,
move, rename, overwrite, truncate, evict or change metadata, or that runs a tool), and what covers it. Functions that
only write Strata's own new files where nothing was (`createDirectory`, a temporary name) are listed with what they
belong to.

| File :: function | Covered by |
|---|---|
| `AI/PlanExecutor :: perform`, `moveBack` | `PlanSafetyTests/runningAPlanDoesOnlyItsCheckedSteps`, `undoKeepsAFolderThePlanMadeOnceSomethingElseIsInIt`, `undoAndRedoOfAPlanTouchOnlyItsOwnItems` |
| `AI/PlanGenerator :: (top level)`, `recipe`, `init`, `expand`; `AI/PlanModel :: init`; `AI/PlanValidator :: validate`, `needFolder`; `AI/RenameRules :: plan` (`rename` here is a plan step's name, not a file call) | `PlanSafetyTests/*`, `RenameTests/*` |
| `AI/SemanticIndex :: reset` | `CacheRemovalTests/resettingTheContentIndexRemovesOnlyItsStore` |
| `App/MainMenu :: build`, `menuNeedsUpdate`, `rename` (menu items; `rename` is a workspace's name) | `WorkspaceTests/*` |
| `Browser/BrowserViewController+ArchiveBrowsing :: unpackForBrowsing` (makes the copy's folder) | `ArchiveSafetyTests/*` |
| `Browser/BrowserViewController+Servers :: renameOnServer` | `ServerSafetyTests/renamingOnAServerStaysInTheFolderAndReplacesNothing` |
| `Browser/BrowserViewController+Trash :: putBack` (remakes missing folders), `deleteAll` | `PutBackTests/*`, `TrashUndoTests/undoingAPutBackRemovesOnlyTheFoldersItMadeOnceEmpty`; `DeleteTests/*` |
| `Browser/BrowserViewController :: resortAnimated` (rows in a table, not files), `renameItem` | `InlineRenameTests/*` |
| `Containers/ContainerCopies :: prepare`, `stackFolder`, `record`, `setAttribute`, `finish`, `setAsideForRemoval` | `ContainerTests/theContainersFolderFollowsTheEngine` … `aContainerCalledLikeAProjectKeepsItsFiles`; `RemoteFilesTests/copiedOutLinksLeadingOutsideAreDropped`, `mergingOutLeavesWhatWasThereAlone`; `CacheRemovalTests/settingCopiesAsideRemovesOnlyThemAtQuit` |
| `Containers/ContainerDrag :: filePromiseProvider` | `ContainerCopyTests/aDraggedOutItemNeverReplacesWhatsAtTheDrop` |
| `Containers/ContainerFiles :: place`, `bringDown`, `apply`, `makeFolders`, `folderFD`, `write`, `makePlaceholder`, `remember`, `restoreTimes`, `setTimes`, `setLinkTimes`, `markDownloaded`, `systemQuarantine` (a probe file of its own), `removeAt` | `ContainerCopyTests/aContainersFolderIsWrittenOnlyIntoItsCopy`, `aCopyThatIsALinkIsNotWrittenThrough`; `ContainerTests/listingsAreWrittenWithoutEscapingTheFolder`, `linksAlwaysResolveInsideTheCopy`, `composeProjectsGroupTheirContainers`, `aLeftoverFolderNamedLikeAProjectMakesWay` |
| `Containers/ContainerFiles :: fetchFile` | `ContainerCopyTests/aFetchedFileTakesOnlyItsPlaceholdersPlace`, `aFetchThatIsntAFileOrFindsSomethingElseChangesNothing` |
| `Dev/GitRepository :: execute` (runs `git`, reads only: `status`, `config`, `ls-files`, hardened against the repository's own config) | `ProjectCleanupTests/*` for what's offered; git's own commands change nothing |
| `Dev/ProjectActions :: openCommandFile` (its own script file), `removeStaleCommandFiles` | `CacheRemovalTests/staleScriptFilesGoOnlyFromTheirFolder`; `ContainerTests/theTerminalScriptQuotesEverything`, `terminalFileNamesArePlainASCII` |
| `Dock/DockSearch :: restartDock` (`killall Dock`: the Dock relaunches, no files) | `DockSearchTests/*` for what's changed in its list |
| `Index/IndexStore :: remove`, `unlink` (an in-memory tree, not files) | `PathQueryTests/*` |
| `Model/ArchiveCache :: finish`, `touch` | `CacheRemovalTests/aNewCopyReplacesOnlyOlderCopiesOfTheSameArchive`, `pruningTakesOnlyStaleCopies` |
| `Model/CloudStatus :: removeDownload` | `DeleteScopeTests/removeDownloadAsksToFreeExactlyTheItemsChosen`, `removeDownloadFreesOnlyWhatsAlsoInTheCloud` |
| `Model/FileInfoEditing :: setComment`, `setLocked`, `setAccess` | `MetadataEditTests/aCommentChangesOnlyTheComment`, `lockingTouchesOnlyThatItem`, `permissionsChangeOnlyThatAccessOnThatItem` |
| `Model/FileOps :: rename`, `moveAll`, `moveItem`, `newFolder`, `newFile`, `trash`, `trashItems`, `removeEmptyFolders`, `registerMoveUndo` | `InlineRenameTests/*`, `RenameTests/*`, `NewFileTests/*`, `TrashUndoTests/*`, `AcrossDisksTests/*` |
| `Model/Places :: eject` (hands the disk to macOS) | not a file change; see above |
| `Model/SecureStorage :: (top level)`, `url`, `removeLegacy`, `sweepStaleTemporaries`, `init`, `commit` | `CacheRemovalTests/savingAStoreReplacesOnlyItsOwnFile`; `DeleteTests/testRunsKeepHistoryAndIndexesOutOfYourOwn`; `DeleteScopeTests/testsKeepToCachesOfTheirOwn` |
| `Model/TagStore :: apply`, `write` | `MetadataEditTests/tagsGoOnTheChosenFilesOnly` |
| `Model/Trash :: removeTree` | `DeleteTests/emptyingATrashDeletesWhatsInItAndNothingElse`, `aTrashThatIsALinkIsNeverFollowed`, `aLockedItemInTheTrashIsReportedAndTheRestGo` |
| `Previews/ArchiveLister :: run` (`zipinfo -l`, `tar -tvf`: listings, nothing written) | `ArchiveSafetyTests/*` for what extraction then does |
| `Remote/LazyCopies :: newFolder` (stages a clipboard copy) | `RemoteFilesTests/theClipboardGetsAFinishedCopy` |
| `Remote/RemoteCopies :: prepare`, `setAsideForRemoval` | `RemoteFilesTests/listsIntoTheCopy`; `CacheRemovalTests/settingCopiesAsideRemovesOnlyThemAtQuit` |
| `Remote/RemoteFiles :: list`, `makeFile`, `rename`, `move`, `fetch`, `place` | `RemoteFilesTests/*`; `ServerSafetyTests/*` |
| `Remote/RemoteSession :: rename`, `upload` (S3) | `S3Tests` rows above (in `DeleteScopeTests`) |
| `Remote/S3Client :: download`, `Remote/SFTPClient :: init`, `rename`, `setTimes`, `download`, `upload` | `S3Tests/downloadsStopAtTheListedSize`; `SFTPClientTests/*` |
| `Settings/SettingsWindowController :: install` | `DeleteScopeTests/theCommandReplacesOnlyItsOwnLink` |
| `Sidebar/SidebarViewController :: menuNeedsUpdate`, `ejectItem`; `Window/BrowserWindowController :: focusSearch`, `ejectVolume`, `validateMenuItem` (Eject) | not a file change; see above |
| `Transfers/Archiver :: compress`, `extractContents`, `unpack`, `check`, `clearAccessList`, `markQuarantined`, `place`, `removeEntry`, `run` (`ditto`, `tar`) | `MetadataEditTests/compressingAddsOneArchiveAndNeverReplacesOne`, `aLinkIsArchivedAsALink`; `ArchiveSafetyTests/*`; `CacheRemovalTests/removingATreeNeverFollowsALinkOut` |
| `Transfers/TransferEngine :: fail`, `copy`, `copyfile`, `rename`, `trash`, `removeIfPresent`, `removeSource` | `TransferTests/*` |
| `Transfers/TransferQueue :: start` (undo's moves) | `TrashUndoTests/undoingAMoveJobMovesBackOnlyItsOwnItems`, `AcrossDisksTests/*` |
| `Views/ClickToRename :: clicked` | `InlineRenameTests/*` |
| `Window/Workspaces :: rename`, `askToRename` (a workspace's name, saved settings) | `WorkspaceTests/*` |
