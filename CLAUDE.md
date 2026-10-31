# Commander

A native macOS dual-panel file manager inspired by Total Commander. It's a personal daily driver: unsandboxed, distributed directly, keyboard first.

Milestone 0 is complete: the app builds and shows an empty window. See PLAN.md for what comes next.

## Where things are

- [PLAN.md](PLAN.md): decisions, v1 scope, keyboard map, architecture and milestones. Check here before adding a feature.
- [PRODUCT.md](PRODUCT.md): who it's for and what it must do.
- [design/commander.html](design/commander.html): clickable prototype of every screen. Sample data only; it touches no real files.
- [DESIGN.md](DESIGN.md): the design system, with tokens for both themes and the rules behind them.

## Build and test

```bash
swift test --package-path Packages/CommanderCore
```

```bash
xcodebuild -project Commander.xcodeproj -scheme Commander build
```

## Stack

- Swift 6 with strict concurrency, targeting macOS 26 or later.
- SwiftUI for the window, dialogs and settings. AppKit `NSTableView` for file panels and the menu bar.
- All logic lives in the `CommanderCore` package, with no UI imports, so it can be tested without launching the app.
- Prefer the platform: `copyfile(3)`, `FileManager`, `DispatchSource`, Quick Look, `NSMetadataQuery`. Add a dependency only when the platform can't do the job.

## Rules for file operations

Data loss is the worst bug this app can have.

- Overwrite through a temp file and rename. Never write directly over an existing file.
- Delete a move's source only after the copy has succeeded.
- Never follow symlinks during recursive copies or deletes.
- Trash is the default. Permanent delete needs explicit confirmation.
- Validate every archive entry path before extracting.
- Bulk work goes through `OperationPreview`, so the preview and the result can't disagree.
- A change to file operations needs tests against real files, not mocks. Use disk images for cross-volume and case-sensitivity cases.

The full list is under "Data safety rules" in PLAN.md.

## Rules for the UI

- Colour means what happens: green copies or creates, yellow moves, red removes or overwrites. A file's own icon is the one exception, because its colours belong to the file and mean nothing. Don't use those colours for anything else, such as success or validation messages, and always pair them with an icon or arrow.
- Keep it dense. Rows are 20px, on one column grid shared by both panels, and panels resize in whole rows.
- Show each fact once.
- Every action needs a keyboard route and a command palette entry.
- Every F-key action also needs a ⌘ shortcut, because Mac laptops treat F-keys as media keys by default.
- Support light mode, dark mode, VoiceOver and reduced motion from the start.
- Follow Mac conventions for menus, shortcuts, focus and system settings.

## Working here

- Work through PLAN.md in milestone order, and tick items off as they land.
- Don't add features outside v1 scope without asking. The out-of-scope list is in PLAN.md.
- When a behaviour changes, update the prototype if the change affects how a screen looks or works.
