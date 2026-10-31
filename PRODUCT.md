# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

The real target is native macOS, which this schema has no value for. `web` applies only to the HTML design previews. Final UI follows macOS conventions for menus, shortcuts, focus and system settings.

## Stack

Swift 6 with SwiftUI for the window, dialogs and settings, and AppKit `NSTableView` for the file panels. Targets macOS 26 or later. Unsandboxed, distributed directly.

## Users

The primary user is the developer who owns this project. It is a personal daily driver, open all day beside the terminal and editor, and used in short keyboard bursts.

## Product Purpose

Commander is a dual-panel file manager for macOS, inspired by Total Commander. It exists because Finder is slow for keyboard-driven and bulk file work. Success means it replaces Finder for daily file work.

## Positioning

- Every action is reachable without the mouse, with no perceptible delay.
- Source and destination are both always visible, so a file operation never loses context.
- Bulk work (renames, syncs, large copies) is previewed before it runs.
- It shows far more files, columns and facts on screen than Finder.

## Operating Context

Short, frequent sessions between coding tasks. Typical work is moving build output, tidying downloads, batch-renaming, inspecting archives, and comparing or syncing folders across local and external volumes.

## Capabilities and Constraints

v1 covers dual panels, tabs, copy, move, delete, marking, quick search, a built-in viewer, a hidden-files toggle, multi-rename, compress (new ZIP or TAR), uncompress, archives as read-only folders, folder compare and sync, inline rename, marking by pattern with invert, back and forward history, go to path, Open Terminal here, copy path, a right-click menu with Open With, and Find Files by name and content.

FTP/SFTP, plugins, branch view and thumbnail view are out of v1.

Mac laptops have no Insert key and F-keys are media keys by default, so every F-key action also needs a Command shortcut.

## Brand Commitments

- The name is Commander.
- A modern reinterpretation of the dual-panel workflow, not a retro clone of Total Commander.
- Must not feel airy or spacious.
- Must not read as a generic Finder clone.

## Evidence on Hand

None yet. No users, benchmarks or testimonials exist, and none should be invented. All file listings in mockups are synthetic.

## Product Principles

- Keyboard first: a mouse is optional everywhere.
- Density over decoration: screen space belongs to the files.
- Show the consequence before the action on any bulk operation.
- Never put user data at risk for speed or convenience.

## Accessibility & Inclusion

Must work with VoiceOver and respect system text contrast, reduced motion, and light and dark settings.
