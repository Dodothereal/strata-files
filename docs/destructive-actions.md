# Destructive actions and their tests

Every way Strata deletes, trashes, moves, renames, overwrites, evicts, or changes the permissions or metadata of
files, on this Mac, on a server, in a container's copy, or in its own stores, with the code that does it and the tests
that cover it (`TestFile/test`, under `Tests/StrataTests`). Each test is proven by a mutation that breaks its rule (see
The proof, below). A change to any of these, or a new one, comes with tests and a row here (see AGENTS.md).

## Delete and the Trash

| Action | Code | Tests |
|---|---|---|
| Move to Trash (⌘⌫, menus, every view) | `BrowserViewController.moveToTrash`, `FileOps.trashInBackground`, `FileOps.canTrash` | `TrashUndoTests/onlyTheSelectionGoesAndUndoPutsItBack`, `aLinkGoesToTheTrashNotWhatItPointsTo`; `DeleteScopeTests/aTrashIsNeverTrashedOrDeletedItself`; `SelectionTargetsTests/*` |
| Delete Immediately (⌥⌘⌫) | `deletionPlan`, `deleteAll` | `DeleteTests/*` (selection only, nested, links, odd names, disks, unchangeable folders, locked, already gone); `DeleteScopeTests/aTrashIsNeverTrashedOrDeletedItself` |
| Empty Trash | `Trash.empty`, `Trash.folders` | `DeleteTests/emptyingATrashDeletesWhatsInItAndNothingElse`, `aTrashThatIsALinkIsNeverFollowed`, `aLockedItemInTheTrashIsReportedAndTheRestGo`; `DeleteScopeTests/emptyTrashOnlyEverEmptiesTrashFolders`, `noOtherFolderCountsAsATrash` |
| Put Back | `putBack`, `Trash.location`, `FileOps.removeEmptyFolders` | `PutBackTests/*`; `TrashUndoTests/onlyEmptyFoldersGoWhenTheirItemsDo`, `undoingAPutBackRemovesOnlyTheFoldersItMadeOnceEmpty` |
| Drop on the sidebar's Trash | `SidebarViewController.canTrash` | `DropTests/theSidebarsTrashTakesOnlyWhatCanBeTrashed` |
| Commands on localized names (every view, results and both panes) | `FileEntry.url`, `BrowserViewController.selectedURLs`; labels use `FileEntry.displayName` | `LocalizedNamesTests/everyViewRenamesTheSelectedURLRatherThanItsTranslatedLabelAndUndoRestoresIt`, `resultsAndBothPanesKeepDifferentItemsWithTheSameLabel`; `SelectionTargetsTests/*` |
| Commands in the combined Applications listing | `ApplicationsFolders`, `DirectoryLoader.load`, `ColumnBrowserViewController.reveal` and `continueReveal`; entries retain physical URLs | `ApplicationsFoldersTests/*` (duplicate names, exact root, both source folders changing, every view, expanded folders, deeper columns, copy to the other pane and rename/undo) |

## Undo and History

| Action | Code | Tests |
|---|---|---|
| ⌘Z / ⇧⌘Z of moves, renames, Move to Trash | `FileOps.registerMoveUndo`, `LandedFiles` | `TrashUndoTests/undoingARenameLeavesAFileSwappedInSince`, `undoAndRedoPressedAtOnceHappenInOrder`, `undoingTwoOperationsAtOnceUndoesBoth`; `AcrossDisksTests/aRenameAcrossDisksUndoesAndRedoes` |
| ⌘Z / ⇧⌘Z of copies, duplicates, move jobs | `TransferUndo.register`, `TransferUndo.perform`, `TransferJob.landed` | `TrashUndoTests/undoingACopyTrashesOnlyItsOwnCopies`, `undoingAMoveJobMovesBackOnlyItsOwnItems`; `TransferTests/undoingACopyLeavesAFileSwappedInWhileTheJobRan`, `aFileSwappedTheMomentItLandsIsNeverUndone`, `aRenamedFileSwappedTheMomentItLandsIsNeverUndone`; `AcrossDisksTests/aMoveJobAcrossDisksUndoesAndRedoesOnlyItsOwnItems`, `undoAndRedoPressedAtOnceAcrossDisksBothHappenInOrder`, `aFileSwappedTheMomentItLandsAcrossDisksIsNeverUndone` |
| ⌘Z of New Folder / New File | `FileOps.registerTrashUndo` | `TrashUndoTests/undoingANewFolderLeavesOneMadeInItsPlace` |
| Undo from History | `OperationLog.undo`, `holdsOriginal`, `FileIdentity.matchesHistory` | `TrashUndoTests/historyUndoBringsBackWhatWasTrashedAndOnlyThat`, `undoLeavesAloneWhatTookTheOldPlace`, `undoNeverMovesBackAnItemThatWasSwappedForAnother`, `undoMovesBackOnlyTheMovedItems`, `historyUndoChecksIdentitiesSavedByOlderVersions`, `HistoryOwnershipTests`, `TransferTests/historyRejectsItemsReplacedBeforeTransferRegistration`, `historyRejectsARenameReplacedBeforeRegistration` |
| Saved History pairs have exactly one source and destination before undo can read them | `OperationLog.Entry.init(from:)` | `HistoryDecodingSafetyTests/malformedHistoryPairsAreRejectedBeforeUndo`, `validAndOlderHistoryRecordsKeepTheirPairs`, `invalidRecordsDoNotHideValidNeighborsOrRewriteHistory`, `unreadableHistoryNeverFallsBackToUnauthenticatedRecords`; mutation: “Malformed History pairs reach undo” |
| Transfer ownership through queued work and Undo/Redo | `TransferQueue`, `TransferJob.registerUndo`, `ArchiveJob.register`, `TransferUndo`, `FileOps.registerLogMark` | `TransferContextTests/*` (private preferences and History, repeated same-disk and cross-disk Undo/Redo, replaced identities, queued archives); mutations: “Transfer ownership” |

## Copy, move, drop, paste

| Action | Code | Tests |
|---|---|---|
| Window and pane transfer ownership | `BrowserServices`, `Pane`, `BrowserWindowController.transferToOtherPane`, `BrowserViewController.transfer` | `TransferContextTests/bothPanesInEveryViewSendOnlyTheirSelectionToTheirOwnQueue`, `replacementPanesAndBrowserCommandsKeepTheWindowServices`, `bothSidebarDropModesUseTheWindowQueue`; mutations: “Browser service ownership” |
| Selection and inline rename after a completed operation | `BrowserWindowController.selectionAfterOperation`, `Pane.destination`, `BrowserViewController.renameWhenShown`, `ColumnBrowserViewController.paneLoaded` | `DirectoryReadSessionTests/*` (applied entries, original pane, navigation and search edits, cancelled rename, native edit completion); mutations: “Applied browser actions” |
| Preparing provider copies before file operations | `CopyProviders.prepareForCopying`, `CopyProviders.fetch`, `LazyCopies` | `CopyProvidersTests/*` (exact owner, mixed selections, errors, prefetch budget); `RemoteFilesTests/theProviderInterfaceUsesItsInjectedServerAndPreservesFetchedFiles`; mutations: “Copy provider routing” |
| Refreshing and removing provider copies | `CopyListings`, `RemoteFiles.refresh`, `RemoteFiles.discard`, `ContainerFiles.refresh`, `ContainerFiles.discard` | `CopyListingsTests/*`; `RemoteFilesTests/invalidatingAnInFlightListingReadsAgainBeforeReportingItFresh`, `discardingACopyDrainsItsListingBeforeRemovingIt`; mutations: “Copy listing coordination” |
| Fetching and disconnecting provider copies | `CopyFetches`, `RemoteFiles.fetchOne`, `RemoteFiles.drainAndRemove`, `ContainerFiles.fetchOne`, `ContainerFiles.fetchTree`, `ContainerFiles.drainAndRemove` | `CopyFetchesTests/*`; `RemoteFilesTests/disconnectWaitsForAnActiveDownloadToStopBeforeRemovingItsCopy`, `cancellingOneServerReaderKeepsAnotherReadersDownloadAlive`, `disconnectAlsoDrainsAutomaticallyPrefetchedFiles`; mutations: “Copy fetch coordination” |
| Copy / move items (engine) | `TransferEngine.perform`, replace, merge, verify | `TransferTests/*` |
| Copy / move jobs (drag and drop, paste, other pane, Duplicate) | `TransferQueue.enqueue`, `TransferJob` | `TransferJobTests/*`, incl. `aReadOnlyCopyTakesNothingAndWhatLeavesItIsCopied` |
| What a drop does | `FileDrop.operation(_:into:mask:option:)` | `DropTests/*` |
| Cut and paste | `Clipboard`, `pasteItems` | `ClipboardTests/*` |

## Rename and new items

| Action | Code | Tests |
|---|---|---|
| Rename (inline, click to rename, Rename menu) | `FileOps.rename` | `InlineRenameTests/*`; `RenameTests/*` |
| Batch rename, swaps and chains | `RenameRules`, `FileOps.moveAll` | `RenameTests/*` |
| New Folder / New File | `FileOps.newFolder`, `newFile`, `BrowserViewController.newFile` | `NewFileTests/*` (incl. `newFolderNeverTakesAnExistingOne`); `TrashUndoTests/undoingANewFolderLeavesOneMadeInItsPlace`; `BrowserPreferencesTests/newFileUsesItsOwnExtensionAndTargetInEveryView` |

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
| Extract and browse an archive | `Archiver.extract`, `extractContents` | `ArchiveSafetyTests/*`, including `browsingAnArchiveNeverReplacesAnExistingFolder` for the copy used to browse |
| Ask Strata plans (rename, move, trash, new folders), their undo and redo | `PlanValidator`, `PlanExecutor`, `PlanTransaction`; created folders use `CreatedFolders` and `removeEmptyFolders` | `PlanSafetyTests/*`, including `undoKeepsAReplacementAtACreatedFolderPath` |
| Cleanup and recreation of folders made for Put Back, queued transfers and History | `CreatedFolders`, `TransferUndo`, `OperationLog.undo`, `FileOps.removeEmptyFolders` | `CreatedFolderOwnershipTests/*` covers captured ownership, replacements before and after transfer completion, symlink targets, failed reads, legacy History, repeated Undo/Redo and cross-disk completion |
| Project cleanup | `ProjectDetector.detectSync`, `isRealDirectory` | `ProjectCleanupTests/*` |
| Git for status badges (a browsed repository's own commands never run, and a disabled driver is no longer required) | `GitRunner.runBlocking`, `hardening`, `repositoryFilterOverrides` | `GitSafetyTests/*` |

## Servers (SFTP, S3)

| Action | Code | Tests |
|---|---|---|
| Delete, move, rename, new items on a server | `RemoteFiles`, `SFTPBackend`, `BrowserViewController.newFileNameOnServer` | `ServerSafetyTests/*`; `RemoteFilesTests/newFilesAreMadeOnTheServerNeverOverAnything`, `deletingALinkLeavesWhatItPointsTo`; `SFTPClientTests/foldersRenamesAndRemoval`; `BrowserPreferencesTests/serverNewFileNamesUseTheirOwnSettingsAndAvoidExistingFilesAndLinks` |
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
| Independent storage contexts and History Undo/Redo retain their key, directory and journal | `SecureStorage.Context`, `OperationLog.init`, `registerRedo`, `FileOps.registerMoveUndo` | `StorageContextTests`; mutations: “Storage isolation” |
| Stores (History, index), content index reset, script files | `SecureStorage.write`, `SemanticIndex.reset`, `ProjectActions.removeStaleCommandFiles` | `CacheRemovalTests/savingAStoreReplacesOnlyItsOwnFile`, `resettingTheContentIndexRemovesOnlyItsStore`, `staleScriptFilesGoOnlyFromTheirFolder` |
| Tests never touch your data, including optimized builds | `SecureStorage.current`, `isTestRun`, `caches` | `DeleteTests/testRunsKeepHistoryAndIndexesOutOfYourOwn`; `DeleteScopeTests/testsKeepToCachesOfTheirOwn` |

## The proof: mutations

`Tests/mutations.json` holds, for every action row above, at least one mutation: a one-line change to the code that
breaks the rule (skips a check, reads it late, applies it to the wrong item), and the tests that must then fail.
`scripts/mutate.py` applies each alone, runs those tests, and restores the file; the **Mutations** workflow runs it
weekly and on request. The runner first checks that the unmodified tests pass. Each run has a five-minute limit;
a timeout, a build failure, or no tests never counts as caught, and stopping the runner restores the source. The
workflow splits the selected rules across four isolated checkouts; together they run every rule exactly once. An
empty rule input selects all rules. Local runs keep using one working tree and apply mutations in order. The
SFTP rename mutation removes both the preflight check and the protocol’s refusal to replace, so the tests reach the
rule instead of passing on the second defense. A row whose tests pass with the rule broken isn't covered, whatever the
map says, so a new test comes with a mutation, and a mutation whose text no longer matches the code is updated, not dropped.

## Not mutated, and why

Functions the audit lists that no mutation reaches, each with the reason. `scripts/audit-destructive.py --check` fails
on any function that is in neither this table nor a mutation.

| Functions | Why no mutation |
|---|---|
| `AI/PlanGenerator :: (top level)`, `recipe`, `init`, `expand`; `AI/PlanModel :: init`; `AI/PlanValidator :: validate`, `needFolder`; `AI/RenameRules :: plan` | `rename` here is a plan step's name, not a file call. The steps are carried out by `PlanExecutor` (mutated). |
| `App/StrataCommand :: init`; `App/MainMenu :: build`, `menuNeedsUpdate`, `rename`; `Window/Workspaces :: rename`, `askToRename` | A workspace's name in saved settings, and the menu items for it. No files. |
| `Browser/BrowserViewController :: resortAnimated` | Moves rows of a table. |
| `Browser/BrowserViewController :: renameItem`; `Views/ClickToRename :: clicked`; `Browser/BrowserViewController+Servers :: renameOnServer` | Hand the typed name to `FileOps.rename` or `RemoteFiles.rename` (both mutated), which hold every check. |
| `Model/Places :: eject`; `Sidebar/SidebarViewController :: menuNeedsUpdate`, `ejectItem`; `Window/BrowserWindowController :: focusSearch`, `ejectVolume`, `validateMenuItem` | Hand a disk to macOS to eject. Nothing of the user's changes. |
| `Dock/DockSearch :: restartDock` | Relaunches the Dock (`killall Dock`). No files. |
| `Index/IndexStore :: remove`, `unlink` | An in-memory tree, not files. |
| `Dev/GitRepository :: execute` | Runs git with the arguments `runBlocking` hardened (mutated); git's own commands here (`status`, `config`, `ls-files`) change nothing. |
| `Dev/ProjectActions :: openCommandFile` | Writes its own script into a fresh folder in the temporary directory; what the script runs is tested (`theTerminalScriptQuotesEverything`). |
| `Previews/ArchiveLister :: run` | Lists an archive (`zipinfo -l`, `tar -tvf`); writes nothing. |
| `Browser/BrowserViewController+ArchiveBrowsing :: unpackForBrowsing`; `Browser/BrowserViewController+Trash :: putBack`; `Containers/ContainerCopies :: prepare`, `stackFolder`, `record`, `setAttribute`; `Containers/ContainerFiles :: makeFolders`, `makePlaceholder`, `setLinkTimes`, `remember`, `restoreTimes`, `setTimes`, `markDownloaded`, `systemQuarantine`; `Remote/RemoteCopies :: prepare`; `Remote/RemoteFiles :: list`, `fetch`; `Remote/LazyCopies :: newFolder`; `Model/SecureStorage :: url`, `init`, `prepare`, `useApplicationStorage`; `Model/ArchiveCache :: touch`; `Transfers/Archiver :: unpack` | Make or mark Strata's own folders, placeholders and temporary files inside its copies and caches (Put Back remakes the folders `Trash.location`, mutated, leads to). Nothing of the user's. |
| `Containers/ContainerFiles :: place`, `bringDown`, `write` | Arrange Strata's copy of a container's files (`theContainersFolderFollowsTheEngine`, `composeProjectsGroupTheirContainers`, `aLeftoverFolderNamedLikeAProjectMakesWay`; `aContainersFolderIsWrittenOnlyIntoItsCopy`). The copy is Strata's own; what comes out of it is covered above. |
| `Model/FileOps :: trash` | Called only by undo, with items an operation itself created (filtered by `LandedFiles`, mutated). What users trash goes through `canTrash` and `deletionPlan` (both mutated). |
| `Model/SecureStorage :: removeLegacy`, `commit` | Remove the old store names Strata itself used; swap its own temporary into place with `rename()`, which replaces a planted link without following it (`savingAStoreReplacesOnlyItsOwnFile`). |
| `Model/TagStore :: apply`, `write` | `canTag` (mutated) keeps links and read-only copies out; tags are the item's own metadata. |
| `Model/Trash :: removeTree` | A link in the Trash is unlinked first and never opened; its `O_NOFOLLOW` guards the instant between those two calls, which no test can time. Links in a Trash are tested (`emptyingATrashDeletesWhatsInItAndNothingElse`). |
| `Remote/RemoteFiles :: makeFile`, `place`; `Remote/RemoteSession :: upload` | Refuse a taken name, then rename under the server's own refusal (`SFTPBackend.rename`, mutated); swap a fetched file over its placeholder inside the copy; replace a file or link as asked (`uploadingOverALinkReplacesTheLink`), never a folder. |
| `Remote/S3Client :: download`; `Remote/SFTPClient :: init`, `rename`, `setTimes`, `download`, `upload` | Protocol calls and the copy's own temporary files; the refusals live in the backends (mutated). |
| `Settings/SettingsWindowController :: install` | Goes ahead only when `mayReplace` (mutated) allows. |
| `Transfers/Archiver :: clearAccessList`, `markQuarantined`, `run` | Act on the extracted copy in Strata's scratch folder before `check` (mutated) and `place` (mutated). |
| `Transfers/TransferEngine :: removeIfPresent`, `removeSource` | Remove the incomplete copy the engine made itself; remove the original only after `changedSinceCopy` (mutated) and verification (mutated) pass. |

## Where the system is stood in for

- **iCloud eviction.** `evictUbiquitousItem` needs a signed-in account, so `CloudActions.removeDownload` takes the
  evict call and the test records exactly which items it's asked to free, in which order, and that it goes on past a
  refusal. What macOS does with an item not in the cloud is tested too: it refuses, and the item stays.
- **The moment an item lands.** `TransferEngine.hooks.afterLanding` is called the instant an item has been placed
  and recorded for undo, before anything else happens to it (also in same-disk `TransferUndo.start`). Tests swap the file right then, for a copy, a rename
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
| `App/StrataCommand :: init`; `App/MainMenu :: build`, `menuNeedsUpdate`, `rename` (menu items; `rename` is a workspace's name) | `WorkspaceTests/*` |
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
| `Model/CreatedFolders :: makeMissing` | `CreatedFolderOwnershipTests/recreationRecordsOnlyFoldersItMakesAndKeepsTryingWhenRequested`, `redoUpdatesOwnershipForLiveAndSavedHistory`, `crossDiskUndoFinishesBeforeRemovingItsCreatedFolders` |
| `Model/FileInfoEditing :: setComment`, `setLocked`, `setAccess` | `MetadataEditTests/aCommentChangesOnlyTheComment`, `lockingTouchesOnlyThatItem`, `permissionsChangeOnlyThatAccessOnThatItem` |
| `Model/FileOps :: rename`, `moveAll`, `moveItem`, `newFolder`, `newFile`, `trash`, `trashItems`, `removeEmptyFolders`, `registerMoveUndo` | `InlineRenameTests/*`, `RenameTests/*`, `NewFileTests/*`, `TrashUndoTests/*`, `AcrossDisksTests/*` |
| `Model/Places :: eject` (hands the disk to macOS) | not a file change; see above |
| `Model/SecureStorage :: (top level)`, `prepare`, `useApplicationStorage`, `url`, `removeLegacy`, `sweepStaleTemporaries`, `init`, `commit` | `CacheRemovalTests/savingAStoreReplacesOnlyItsOwnFile`; `DeleteTests/testRunsKeepHistoryAndIndexesOutOfYourOwn`; `DeleteScopeTests/testsKeepToCachesOfTheirOwn` |
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
| `Transfers/TransferQueue :: start` (undo's moves) | `TrashUndoTests/undoingAMoveJobMovesBackOnlyItsOwnItems`, `AcrossDisksTests/*`, `TransferTests/sameDiskUndoStepsNeverAdoptItemsReplacedBeforeRegistration` (captured identity, conflicts, replacements, failed moves and repeated Undo/Redo) |
| `Views/ClickToRename :: clicked` | `InlineRenameTests/*` |
| `Window/Workspaces :: rename`, `askToRename` (a workspace's name, saved settings) | `WorkspaceTests/*` |
