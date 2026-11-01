# Commander plan

Commander is a native macOS dual-panel file manager inspired by Total Commander. It is a personal daily driver, built to replace Finder for keyboard-driven and bulk file work.

The working design is [design/commander.html](design/commander.html), a clickable prototype of every screen. Open it in a browser and press ⌘K to see all commands. Where this plan and the prototype disagree on behaviour, this plan wins; where they disagree on look, the prototype wins.

## Decisions

| Area | Decision |
|---|---|
| Distribution | Direct and unsandboxed, signed locally for this Mac. Developer ID and notarization if it's ever shared. No Mac App Store. |
| Target | macOS 26 or later, Apple silicon first. |
| Language | Swift 6 with strict concurrency. |
| UI | SwiftUI for the window, dialogs and settings. AppKit `NSTableView` for file panels and the Mac menu bar. |
| Structure | One app target plus a local `CommanderCore` Swift package with no UI code. |
| File access | A `FileSource` protocol with local and archive implementations. |
| Listing | `FileManager` first. Move to `getattrlistbulk` only if measured as slow. |
| Live refresh | `DispatchSource` watcher on the current folder, plus manual refresh for network volumes. |
| Copying | `copyfile(3)` with `COPYFILE_CLONE`, walking folders ourselves so each file gets its own conflict decision. |
| Archives | System `libarchive` with matching headers. Vendor it only if the milestone 6 spike fails. |
| Search | `NSMetadataQuery` for Spotlight, plus a folder walker for volumes Spotlight doesn't index. |
| Design | Keyed, with preview rows in the destination before bulk work runs. |
| Tests | Swift Testing against real temp folders, with disk images for cross-volume cases. |

## v1 scope

**In:** dual panels, tabs, sorting, marking, mark by pattern, invert, quick search, hidden files, history, go to path, viewer, copy, move, Trash, inline rename, multi-rename, command palette, command line, Open Terminal here, copy path, right-click menu with Open With, compress, uncompress, archives as read-only folders, compare and sync, Find Files, real file icons, tabs that move between panes, settings, native menu bar.

**Out of v1:**
- FTP/SFTP
- Thumbnail view
- Branch view
- Rebindable keys
- Permissions and tags editing
- Undo for copy and move (the first candidate after v1)
- Checksum tools
- File splitting
- Auto-update
- Adding to or deleting from an existing archive
- Creating 7z or RAR
- Total Commander plugins, which are Windows DLLs and cannot run on macOS

## Design rules

- **Colour means what happens.** Green copies or creates, yellow moves, red removes or overwrites. Nothing else uses those colours, apart from a file's own icon, whose colours belong to the file. Each is always paired with an icon or arrow.
- **The consequence shows first.** Bulk work appears as preview rows in the destination, and the preview scrolls to any conflict.
- **Density is the point.** 20px rows on one column grid shared by both panels. Panels resize in whole rows and never clip one.
- **Each fact appears once.** Marked count and size live in the key column, totals in the panel footer, the path in the path bar.
- **Keyboard first.** Every action works without the mouse and is listed in the command palette.

## Data safety rules

These apply from milestone 3 on and have no exceptions.

1. Overwrites write to a temp file, then rename into place, so a cancel or crash never destroys the existing file.
2. A move across volumes deletes the source only after the copy succeeds.
3. Copying a file onto itself, or a folder into itself, is refused. This includes copies from Find results.
4. Symlinks are copied as links and never followed during recursive copies or deletes.
5. Trash is the default. Permanent delete needs an explicit confirmation.
6. If the destination file is newer, the default conflict choice is Skip.
7. Hidden files are unmarked when hidden, so an operation never touches a file you can't see.
8. Sync deletions are off by default and always go to Trash.
9. Archive extraction rejects any entry that would land outside the target folder, including through symlinks.
10. If marked files from different folders share a name, the copy is refused rather than letting one overwrite the other.

## Keyboard

Mac laptops have no Insert key, and F-keys are media keys by default, so every F-key action also has a Command shortcut.

| Action | Keys |
|---|---|
| Switch panel | Tab |
| Mark and show folder size | Space |
| Mark or unmark by pattern | + / - |
| Invert marks | * |
| Mark all | ⌘A |
| Clear marks or end a search | Esc |
| Quick Look | ⇧F3 or ⌘⇧Y |
| Open | Return |
| Up a folder | Backspace or ⌘↑ |
| Open a package as a folder | ⌘↓ |
| Refresh | ⌘R |
| Back / forward | ⌘[ / ⌘] |
| Go to path | ⌘⇧G |
| View beside | F3 or ⌘Y |
| Viewer: text or hex | H in the viewer, or ⌘⇧H |
| Viewer: focus | Tab, and Tab again to leave |
| Edit | F4 or ⌘E |
| Copy to other panel | F5 or ⌘⇧C |
| Move to other panel | F6 or ⌘⇧M |
| New folder | F7 or ⌘⇧N |
| Move to Trash | F8 or ⌘⌫ |
| Rename in place | ⇧F6 or ⌥⌘R |
| Multi-rename | ⌘⇧R |
| Compress / uncompress | ⌘⇧P / ⌘⇧U |
| Compress: ZIP or TAR.GZ | Tab in the name field |
| Compare and sync | ⌘⇧D |
| In compare: set direction, skip, trash | ← →, -, X |
| In compare: mode, differences, allow deletions | 1 2 3, D, A |
| In compare: show line differences | Space |
| Find Files | ⌘F |
| In Find: this folder, this volume, all volumes | ⌘1 ⌘2 ⌘3 |
| In results: stop the search, then close the tab | Esc |
| Hidden files | ⌘⇧. |
| Command palette | ⌘K |
| Command line | ⌘L |
| Open Terminal here | ⌘⇧T |
| Copy path | ⌥⌘C |
| Right-click menu | ⇧F10 or ⌥⌘M |
| New / close tab | ⌘T / ⌘W |
| Next / previous tab | ⌘⇧] / ⌘⇧[ |
| Move tab to other panel | ⌥⌘T |
| Move tab left / right | ⌥⌘[ / ⌥⌘] |
| Choosing tabs to compare: first, second | ↑ ↓, ← → |
| Sort by name, extension, size, modified | ⌃⌘1 to ⌃⌘4 |
| Undo rename | ⌘Z |

## Structure

```text
Commander.xcodeproj
Commander/                 App target: windows, panels, key column, dialogs, menus
Packages/CommanderCore/
  Sources/CommanderCore/
    Model/                 FileEntry, PanelState, TabState, Selection
    Sources/               FileSource, LocalSource
    Archive/               ArchivePath, reader, RoutedSource, extractor, writer
    Jobs/                  JobQueue, CopyEngine, ConflictPolicy, OperationPreview
    Rename/                Pattern parser and renamer
    Compare/               Tree comparer and sync planner
    Search/                Spotlight and folder-walk search
  Tests/CommanderCoreTests/
design/commander.html      Prototype
```

Three types carry most of the design:

- **`FileSource`** lists, reads and watches a location. Local folders and archives both implement it, and FTP/SFTP could be added the same way later.
- **`OperationPreview`** is a pure description of what a bulk operation would do. Copy, move, Trash, rename, compress, extract and sync all produce one. The UI draws it as preview rows, and the job queue executes the same object, so the preview cannot disagree with the result.
- **`JobQueue`** is an actor that runs operations in the background, one at a time per destination, with progress and cancel.

## Milestones

Each milestone ends with something usable, and each must meet its exit criteria before the next starts. Nothing in milestone 4 or later may build on the job queue until milestone 3's tests pass.

### M0: Project setup

Create the empty project everything else builds on.

- [x] Add `.gitignore`, covering build output, `.playwright-mcp/` and `.impeccable/review/`
- [x] Create the `CommanderCore` package
- [x] Create the Xcode app target
- [x] Turn on Swift 6 strict concurrency
- [x] Add a first passing test in Swift Testing
- [x] Open a window with two empty panels and the key column

**Exit:** the app builds and launches, and `swift test` passes in `CommanderCore`.

### M1: Browse

A read-only file browser you can drive without the mouse.

- [x] `FileEntry`, `FileSource` and `LocalSource`
- [x] `NSTableView` panels with the shared column grid and whole-row sizing
- [x] Natural sorting, folders first, with case and Unicode handling
- [x] Cursor, Tab between panels, keyboard navigation
- [x] Back, forward, up, and go to path
- [x] Tabs with new, close, next and previous
- [x] Clickable path bar, plus a volumes and favorites menu with mount notifications
- [x] Live refresh and manual refresh
- [x] Hidden files toggle
- [x] Permission errors that explain Full Disk Access and link to it
- [x] `.app` and other packages: Return launches, a separate shortcut opens as a folder

**Exit:** you can navigate for a day without the mouse. A 100k-file folder opens and scrolls without visible stutter.

### M2: Selection and shell

The app starts to feel like Commander, still without changing any files.

- [x] Marking with Space, ⌘A, mark by pattern and invert
- [x] Live pattern preview in the status bar
- [x] Quick search by typing, with a no-match state
- [x] Folder size calculation in the background
- [x] Key column with counts, direction arrow and disabled states
- [x] Native menu bar with every command
- [x] Session restore for tabs, folders and window size
- [x] Quick Look on F3
- [x] Light and dark themes
- [x] Settings window for theme, default editor and hidden-files default

**Exit:** every read-only command works from the keyboard and the menu bar, in both themes, and state survives a relaunch.

### M3: File operations

The highest-risk milestone, because this is where data can be lost.

- [x] `OperationPreview` for copy, move and Trash
- [x] Preview rows in the destination, scrolled to any conflict
- [x] `JobQueue` with progress, cancel and a visible queue
- [x] `CopyEngine` on `copyfile(3)` with temp-then-rename
- [x] Conflict choices: Replace, Skip, Keep both, with the newer-file default
- [x] Keep both checks for a free name instead of assuming one
- [x] Copy, move, new folder, Trash, permanent delete
- [x] Inline rename with undo
- [x] File clipboard and drag and drop
- [x] Right-click menu with Open With, acting on the clicked row unless it is part of the marked set

**Tests:** cancel mid-file, crash safety of overwrites, symlinks, extended attributes, resource forks, APFS clones, cross-volume moves, a full destination, permission failures, copy onto self, folder into itself. Use disk images for HFS+, case-sensitive APFS and FAT.

**Exit:** data safety rules 1 to 7 and 10 are covered by passing tests, and a copy of 10k mixed files verifies byte-identical.

**Status:** code complete, with 153 tests passing and the 10k copy byte-identical. Everything has been tried in the running app, including F-keys, ⌘ shortcuts, clipboard paste, Move Here, the right-click menu, Open With, Quick Look and drag and drop. One gap: Option and Command drags couldn't be simulated, so forcing a copy or a move while dragging still needs a hand check.

### M4: Command layer

- [x] Command palette with filtering, listing every command
- [x] Command line that runs in the active panel's folder
- [x] F4 opens the default editor
- [x] View beside: the viewer takes over the other panel and follows the cursor
- [x] Paged text and hex viewer for huge files
- [x] Open Terminal here and copy path

**Exit:** a multi-GB log opens without delay, and every command is reachable from the palette.

**Status:** code complete, with 200 tests passing. A 6 GB file opens and jumps to its end at once. Tried in the running app: the palette, the command line, the viewer in every mode, and following the cursor. Open Terminal Here was tried with Ghostty. F4 and Copy Path are tested through their hand-off only, so they still need a real try.

Decided in M4:

- The viewer reads windows with `pread` instead of a memory map. A mapped file that shrinks, or whose volume goes away, kills the process, and logs get rotated while they're read.
- F3 is View Beside, as the prototype has it. Quick Look moves to ⇧F3 and ⌘⇧Y, and images, PDFs and media open with Quick Look inside the viewer.
- The command line runs through the login shell with no terminal attached, and output opens in the viewer. `cd` moves the panel. Interactive programs need Open Terminal.
- The palette lists what exists now. Each later milestone adds its own commands.
- Settings picks the terminal for ⌘⇧T, falling back to the system's default. F4 uses the Default editor setting, or else the file's default app.

### M5: Multi-rename

- [x] Pattern parser with `[N]`, `[N1-5]`, `[E]`, `[C]`, `[YMD]`
- [x] Find and replace with regex, case conversion, counter start, step and digits
- [x] Before and after view with live conflict detection, windowed for large sets
- [x] Rename through temp names so swaps work
- [x] Undo

**Tests:** every token, `[YMD]` using the local date, literal replacement of `$`, collisions inside the set and with existing files, invalid names, `a→b` with `b→a`, partial failure.

**Exit:** renaming 1,000 files previews live and can be undone in one step.

**Status:** code complete, with 248 tests passing. Tried in the running app on 1,200 files: live preview, collision errors, the run, Undo and Redo in one step, Esc and Page Down. The right-click entry and the real ⌘⇧R keystroke haven't been tried by hand.

Decided in M5:

- A rename is all or nothing. Any failure puts every file back, because a half-renamed set is harder to fix than an error.
- Folders are left out of the marked set, as in the prototype, but packages count as files. Inline rename still handles a folder, and the Rename key and ⌘⇧R go there when a lone folder is on the cursor.
- Find, Replace and Case apply to the name, not the extension.

### M6: Archives

Start with the spike, because the rest depends on its answer.

- [x] Spike: link the system `libarchive` with matching headers and confirm ZIP, TAR, GZ, 7z and RAR reading. If a format is missing or the linkage is unsafe, vendor the library.
- [x] `ArchiveSource` so archives open as read-only folders
- [x] Extract to the other panel, with preview rows
- [x] Copy out of an archive
- [x] Compress to a new ZIP or TAR.GZ
- [x] Decide how password-protected archives behave

**Tests:** malicious archives with `../` paths, absolute paths and symlink escapes; corrupt and truncated files; very large archives.

**Exit:** a malicious archive cannot write outside its target folder, and all listed formats open.

**Status:** code complete, with 306 tests passing. Tried in the running app: opening a ZIP and a 7z, copying a folder out, extracting a hostile TAR, and compressing to ZIP and TAR.GZ. Not yet tried by hand: password-protected archives and very large archives.

Decided in M6:

- The spike passed, with one change to the plan. macOS ships `libarchive` but no headers, so `Sources/CArchive` declares only the functions used, with signatures taken from libarchive 3.7. ZIP, TAR, GZ, 7z and RAR all read, so nothing is vendored.
- A damaged archive lists what comes before the damage and says so, rather than showing nothing.
- Password-protected archives aren't unlocked in v1. A ZIP lists normally, and extracting reports those files as password-protected. An archive that also hides its file names says so when opened.
- Inside an archive a location is a plain path through the file, such as `/x/a.zip/sub`, so tabs, history and session restore work unchanged.
- Archives are read-only. Move, Trash, rename and new folder are refused there, and nothing can be copied in.
- Files can be opened from inside an archive through a temporary copy. View Beside and Quick Look ask you to copy the file out first.
- Compressing keeps links, permissions and dates, but not extended attributes or resource forks.

### M7: Compare and sync

- [x] Tree comparer by name and date, size, or content
- [x] Byte comparison that stops at the first difference
- [x] Aligned two-sided view with per-row direction keys
- [x] Sync plan as an `OperationPreview`, run through the job queue
- [x] Deletions off by default and always to Trash
- [x] Deletion applies only to a file that exists on one side, never to both copies
- [x] Tolerance for FAT's 2-second timestamps
- [x] Unicode and case normalization for name matching
- [x] File diff view for two text files

**Exit:** a sync cannot run without showing its preview. Volumes with different case rules and Unicode forms produce no false differences.

**Status:** code complete, with 366 tests passing. Tried in the running app with real keystrokes: all three compare modes, the Differences filter, direction keys, skip, allowing deletions, the diff view, and a sync including a Trash. Disk images cover case rules and FAT dates. A sync across two real external volumes hasn't been tried.

Decided in M7:

- The compare screen is the sync's preview, and `runSync` only works from it, so a sync can't run unseen.
- A file changed after the comparison is refused at run time, on either side, and reported.
- A folder that can't be read shows as unreadable and its contents stay out. Otherwise everything in it would look missing and be offered for copying.
- A folder on one side only is one row, copied or trashed whole.
- The same date with different sizes is shown as a difference with no direction, because nothing says which side is right.
- Matching names ignore case when either volume does. Dates count as equal within 1 second, or 2 where a volume stores coarse times.
- Hidden files follow the panel setting, and system clutter such as `.DS_Store` and `._` files is never a difference.
- After a sync, rows the user skipped stay skipped, and a held Return can't start a second sync.
- A folder going to Trash is refused if its date changed since the comparison. Its date only shows changes directly inside it.
- Only regular files are read, so a named pipe shows as unreadable and a link's target is never opened for a line diff.
- The compare screen shows the left panel against the right. Pressing Space on a row shows the text diff.

### M8: Find Files

- [x] Search by name pattern and by content
- [x] Spotlight when the volume is indexed, folder walk otherwise
- [x] Scope: this folder, this volume or all volumes
- [x] Results open as a tab, usable for copy and compress
- [x] Return opens a result's folder
- [x] Cancel, and live results while searching

**Exit:** the same search finds the same files on an indexed internal volume and an unindexed external one.

**Status:** code complete, with 426 tests passing, repeated runs of the whole suite staying clean. Tried in the running app: name and content search, folder and volume scope, the results tab and its Folder column, Keep Results, Return to the folder and Back, closing with Esc, Cancel, and a search of the whole startup disk, with a test showing Spotlight answers from the top of the disk. The exit test is covered by comparing a disk image with a temp folder. ⌘1 and ⌘3 were tried in M8.5. Not yet tried by hand: All Volumes, a real unindexed external drive, stopping a long search with Esc, and copy and compress from results with real keys.

Decided in M8:

- The walk decides the answer, and Spotlight only makes hits arrive sooner. Every hit is checked by the walk's own rules, so an indexed volume and an unindexed one give the same files, and a folder Spotlight doesn't cover can't come back empty.
- Spotlight runs on a thread of its own, which nothing else touches. Stopping a query can wait on the thread that asked, so on the main thread it froze the app. It's built from arguments rather than a query string, because a string it can't parse raises an exception Swift can't catch.
- Hidden files, packages, other volumes and `/System` are left out of a search, the way a panel shows them. Content is matched as bytes with ASCII case folded, so accents and UTF-16 aren't matched.
- Content search never reads a file iCloud has taken off the disk, because that would download it. Such a file counts as unreadable.
- A Find tab left with nothing typed closes itself.
- Results stop at 100,000, and a search that didn't finish says so in the footer.
- Results arrive in the order found and are sorted once the search ends, so rows don't shift under the cursor.
- Move, Trash, rename and new folder need the real folder, and nothing can land in a results tab. Dropping or pasting into one is refused. Dragging out of one still follows the usual move or copy rule.
- A results tab reopens as its starting folder after a relaunch.

### M8.5: Icons and tabs

**Real file icons**

- [x] `FileIcons` in the app target, since the core has no UI imports
- [x] Icons by type from `NSWorkspace.icon(for:)`, cached by extension, so listing a folder reads nothing more from disk
- [x] Per-file icons for apps, other packages and custom folder icons, loaded off the main thread and cached by path, with the type's icon showing until they land
- [x] Links keep the system's arrow badge, and files inside archives use their type's icon
- [x] Icons at 16px in the existing 19px gap, so the name column doesn't move and rows stay 20px
- [x] The same icons in results tabs, multi-rename and compare
- [x] Hidden files dim their icon. `..` keeps its arrow
- [x] Preview rows keep the action's plus, alert or trash icon, so the action colour stands alone there
- [x] Update the colour rule in CLAUDE.md, DESIGN.md and this plan: green, yellow and red in a file's own icon come from that file and mean nothing

**Tabs**

- [x] Give each tab a stable id, because the strip is keyed by position today and that breaks once tabs move
- [x] A + button on the strip, and × on the selected or hovered tab. No × when a pane has one tab
- [x] Drag to reorder within a pane
- [x] Drag to the other pane. Its folder, history, sort, cursor, marks and results go with it, and that pane becomes active
- [x] Moving a pane's only tab leaves a new tab on the same folder, because a pane can't be empty
- [x] Keep moving a tab keyboard-first: ⌥⌘T to the other pane, ⌥⌘[ and ⌥⌘] to reorder, each with a menu item, a palette entry and a VoiceOver action
- [x] No tab moves while a preview, a bar, multi-rename or compare is open, because those hold on to their panel
- [x] A results tab keeps filling after a move, so a search finds its tab in either pane
- [x] Many tabs shrink to a minimum width and then scroll, so the strip can't push the panel wider

**Compare any two tabs**

- [x] `beginCompare` takes two folders rather than reading the panels, and keeps its checks: same folder, one inside the other, archives and results
- [x] With one tab in each pane, ⌘⇧D opens at once, as it does now
- [x] With more tabs, ⌘⇧D opens a status bar mode with both choices filled in from the visible tabs, so Return gives today's result and picking another tab takes one extra step
- [x] Two tabs in the same pane can be compared. The first is the left side of the compare screen
- [x] Sync still runs only from the compare screen, and it refreshes whichever tabs show those folders

**Also**

- [x] Prototype: + and ×, tab dragging, the compare choice, and sample coloured icons
- [x] Tests against real files for moving and reordering, including marks, history, a running search and the refused cases

**Exit:** a folder of mixed files shows the same icons as Finder with no slowdown at 100k files, a tab with marks and history can be moved across and back with only the keyboard, and two tabs in one pane can be compared and synced.

**Status:** code complete, with 457 tests passing. Tried in the running app with real input: icons in a mixed folder and in home, the + and × buttons, dragging a tab to the other panel, reordering it by either half of a tab, ⌥⌘T, ⌥⌘[, long titles truncating, the compare choice with its arrow keys and Return, icons and empty sides in compare, and a 100,000-file folder paging end to end at once. Moving and comparing with marks, history and a running search are covered by tests against real files. Not yet tried by hand: icons in multi-rename, ⌥⌘], a live theme change, and VoiceOver on the new tab actions. Icons were judged by eye rather than compared with Finder file by file.

Decided in M8.5:

- A row draws its type's icon at once, which reads nothing from disk, and its own icon arrives from a background queue. The newest 512 requests wait, newest first and each file once, which holds every row of two tall panels while scrolling past thousands doesn't build up work.
- A tab is a plain drag surface rather than a Button, which would take the mouse-down and stop the drag.
- Dragged tabs use a private type, `dev.commander.tab`, declared in `Commander-Info.plist` and visible only inside the app, so text fields and other apps can't take one. The system won't match an undeclared type to a drop.
- Dropping on a tab's left half lands before it, and on its right half after it.
- Sort keys swap between Ext and Folder as a tab moves between a folder and results, so a tab is never sorted by a column it doesn't show.

### M9: Release

- [ ] Listen to VoiceOver on every screen
- [x] Reduced motion
- [ ] See Increase Contrast on screen
- [x] Keyboard focus check
- [x] App icon
- [x] Signing for this Mac
- [ ] Use it as the daily file manager for two weeks and fix what comes up

**Exit:** Finder is no longer needed for daily file work.

**Status:** three items need a person. The VoiceOver work is done in code, with every row, status message, compare row, diff line and palette choice now spoken, and the end of a search announced, but nobody has listened to it. Increase Contrast is measured and coded, but the system setting hasn't been switched on to see it. The two weeks of daily use haven't started. A signed Release build runs, and lists and sorts 100,000 files in 1.3 seconds against the 3-second target. 458 tests pass.

The keyboard focus check ran on that signed build with real keys: after Find, Go to Path, the mark bar, the palette, a compare refusal and the viewer, the arrow keys still moved the cursor, and Tab crossed panels and back. Focus after multi-rename and compress was checked in their own milestones.

Decided in M9:

- Signing is local for now. `scripts/release.sh` with `IDENTITY` set to the Apple Development certificate gives a hardened, timestamped build whose identity holds across rebuilds, so Full Disk Access should carry over. It isn't notarized, so it's for this Mac only, and Gatekeeper rejects it on assessment. The certificate came from a free Personal Team and expires on 31 October 2027. Sharing the app needs the paid Apple Developer Program, and the same script then notarizes.
- The icon is `Commander/Commander.icon`, a native Icon Composer document, because that format can hold HDR and PNGs can't. Only the Copy key goes past white, at `extended-srgb` green 1.15, which still reads as the key's green on an SDR display. The compiled catalog keeps that value. Whether the Dock lights it up needs an HDR display to see.
- Run buttons draw their own fill and use the keys' dark inks, because white on green was 3.2:1, on yellow 3.15:1, and a system prominent button turns grey in an inactive window. Trash red went from #D8412F to #D23C2A, for 4.75:1 with white.
- Increase Contrast is read directly from the system, because a theme forced in Settings is a plain appearance that wouldn't report it. Row bands have their own token, which stays put, so text on them gains contrast rather than losing it.
- A folder-watcher refresh stands aside during a rename, because listing halfway through could leave the cursor on a neighbouring file. That bug dated from M5, and a rare test failure exposed it.
- A short window drops the keys' printed names, so each key has a tooltip.
- A row press becomes a file drag only after moving 5pt, because a click always moves a little. Without that, a click could start a drag over its own panel and highlight the whole table. A file also can't drop back into the folder it's already in.
- A trackpad scrolls freely and settles on a whole row when it stops, because stepping 20pt at a time juddered. A mouse wheel still moves in whole rows.
- The viewer keeps one Quick Look view for every file, because a new one showed black until its first page was ready.

## Open questions

None. Decided along the way: the domed keys are a SwiftUI `ButtonStyle`, macOS 26 is the minimum, ⌘↓ opens a package as a folder, New, Compress and Extract stay neutral, and run buttons repeat the count.

## Risks

- **Data loss in M3.** This is the largest risk, which is why that milestone has the strictest tests and later work depends on it.
- **Laptop F-keys.** They need Fn or a system setting, so the ⌘ shortcuts must be first-class, not a fallback.
- **Privacy prompts.** Unsandboxed apps still trigger them, and protected folders need Full Disk Access.
- **Spotlight gaps.** External volumes are often unindexed, so Find Files needs the folder walker from the start.
- **Unverified performance.** The 100k-file target is a goal. Nothing has been measured, and the prototype says nothing about native speed.
