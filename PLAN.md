# Commander plan

Commander is a native macOS dual-panel file manager inspired by Total Commander. It is a personal daily driver, built to replace Finder for keyboard-driven and bulk file work.

The working design is [design/commander.html](design/commander.html), a clickable prototype of every screen. Open it in a browser and press ⌘K to see all commands. Where this plan and the prototype disagree on behaviour, this plan wins; where they disagree on look, the prototype wins.

## Decisions

| Area | Decision |
|---|---|
| Distribution | Direct, unsandboxed, Developer ID notarized. No Mac App Store. |
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

**In:** dual panels, tabs, sorting, marking, mark by pattern, invert, quick search, hidden files, history, go to path, viewer, copy, move, Trash, inline rename, multi-rename, command palette, command line, Open Terminal here, copy path, right-click menu with Open With, compress, uncompress, archives as read-only folders, compare and sync, Find Files, settings, native menu bar.

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

- **Colour means what happens.** Green copies or creates, yellow moves, red removes or overwrites. Nothing else uses those colours. Each is always paired with an icon or arrow.
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
| Compare and sync | ⌘⇧D |
| Find Files | ⌘F |
| Hidden files | ⌘⇧. |
| Command palette | ⌘K |
| Command line | ⌘L |
| Open Terminal here | ⌘⇧T |
| Copy path | ⌥⌘C |
| Right-click menu | ⇧F10 or ⌥⌘M |
| New / close tab | ⌘T / ⌘W |
| Next / previous tab | ⌘⇧] / ⌘⇧[ |
| Sort by name, extension, size, modified | ⌃⌘1 to ⌃⌘4 |
| Undo rename | ⌘Z |

## Structure

```text
Commander.xcodeproj
Commander/                 App target: windows, panels, key column, dialogs, menus
Packages/CommanderCore/
  Sources/CommanderCore/
    Model/                 FileEntry, PanelState, TabState, Selection
    Sources/               FileSource, LocalSource, ArchiveSource
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
- Folders are left out of the marked set, as in the prototype, but packages count as files. Inline rename still handles a folder.
- Find, Replace and Case apply to the name, not the extension.

### M6: Archives

Start with the spike, because the rest depends on its answer.

- [ ] Spike: link the system `libarchive` with matching headers and confirm ZIP, TAR, GZ, 7z and RAR reading. If a format is missing or the linkage is unsafe, vendor the library.
- [ ] `ArchiveSource` so archives open as read-only folders
- [ ] Extract to the other panel, with preview rows
- [ ] Copy out of an archive
- [ ] Compress to a new ZIP or TAR.GZ
- [ ] Decide how password-protected archives behave

**Tests:** malicious archives with `../` paths, absolute paths and symlink escapes; corrupt and truncated files; very large archives.

**Exit:** a malicious archive cannot write outside its target folder, and all listed formats open.

### M7: Compare and sync

- [ ] Tree comparer by name and date, size, or content
- [ ] Byte comparison that stops at the first difference
- [ ] Aligned two-sided view with per-row direction keys
- [ ] Sync plan as an `OperationPreview`, run through the job queue
- [ ] Deletions off by default and always to Trash
- [ ] Deletion applies only to a file that exists on one side, never to both copies
- [ ] Tolerance for FAT's 2-second timestamps
- [ ] Unicode and case normalization for name matching
- [ ] File diff view for two text files

**Exit:** a sync cannot run without showing its preview. Volumes with different case rules and Unicode forms produce no false differences.

### M8: Find Files

- [ ] Search by name pattern and by content
- [ ] Spotlight when the volume is indexed, folder walk otherwise
- [ ] Scope: this folder, this volume or all volumes
- [ ] Results open as a tab, usable for copy and compress
- [ ] Return opens a result's folder
- [ ] Cancel, and live results while searching

**Exit:** the same search finds the same files on an indexed internal volume and an unindexed external one.

### M9: Release

- [ ] Full VoiceOver pass over every screen
- [ ] Reduced motion, increased contrast and keyboard focus check
- [ ] App icon
- [ ] Developer ID signing and notarization
- [ ] Use it as the daily file manager for two weeks and fix what comes up

**Exit:** Finder is no longer needed for daily file work.

## Open questions

Decided in M0: the domed keys are a SwiftUI `ButtonStyle` built from a radial gradient and shadows, and macOS 26 stays the minimum. Decided in M1: ⌘↓ opens a package as a folder.

| Question | Decide by |
|---|---|
| Does the system `libarchive` cover 7z and RAR, and is linking it safe? | Start of M6 |
| How should password-protected archives behave? | M6 |
| Should New, Compress and Extract keys be green, since green means copy or create? They are neutral in the prototype. | M2 |
| Should the run button repeat the count ("Copy 6 items"), given that each fact appears once? | M3 |

## Design fixes to carry into the app

The prototype still has these small gaps. Fix them in the native build, not the prototype.

- White on Trash red is 4.45:1, just under the 4.5:1 target for small text.
- Red status counts such as "1 replaced" have no icon of their own.
- Pattern and Find fields use the sans font, though masks are meant to be mono.
- Status messages use dim ink, and the Go to error has no icon.
- The command palette input has no focus ring.
- Under 760px of height, keys lose their visible labels.
- Follow live system theme changes; the prototype reads the theme only at load.

## Risks

- **Data loss in M3.** This is the largest risk, which is why that milestone has the strictest tests and later work depends on it.
- **Laptop F-keys.** They need Fn or a system setting, so the ⌘ shortcuts must be first-class, not a fallback.
- **Privacy prompts.** Unsandboxed apps still trigger them, and protected folders need Full Disk Access.
- **Spotlight gaps.** External volumes are often unindexed, so Find Files needs the folder walker from the start.
- **Unverified performance.** The 100k-file target is a goal. Nothing has been measured, and the prototype says nothing about native speed.
