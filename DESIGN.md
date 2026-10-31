---
name: Commander
description: A keyboard-first dual-panel file manager for macOS where colour says what a key will do.
colors:
  go: "#3FA34D"
  go-hi: "#58C168"
  go-ink: "#0D240F"
  go-t: "#86DC94"
  go-bg: "rgba(63,163,77,.2)"
  mv: "#F2B705"
  mv-hi: "#FFD24E"
  mv-ink: "#2F2300"
  mv-t: "#F7CF58"
  mv-bg: "rgba(242,183,5,.17)"
  rm: "#D8412F"
  rm-hi: "#EC6A59"
  rm-ink: "#FFFFFF"
  rm-t: "#F6A094"
  rm-bg: "rgba(216,65,47,.22)"
  case: "#262523"
  deck: "#1E1D1C"
  rim: "#000000"
  line: "#3A3936"
  ink: "#ECE8DE"
  dim: "#A7A296"
  cur: "#D9D5CA"
  cur-ink: "#1A1917"
  field: "#161514"
  key: "#3A3834"
  key-hi: "#55524C"
  key-ink: "#ECE8DE"
  light-case: "#DDD9CF"
  light-deck: "#F3F1EB"
  light-rim: "#B9B4A7"
  light-line: "#CFCABD"
  light-ink: "#1E1D1B"
  light-dim: "#5E5A51"
  light-cur: "#2B2A27"
  light-cur-ink: "#F3F1EB"
  light-field: "#FBFAF6"
  light-go-t: "#1B6A28"
  light-mv-t: "#6E5000"
  light-mv-bg: "rgba(242,183,5,.26)"
  light-rm-t: "#A02719"
  light-rm-bg: "rgba(216,65,47,.15)"
  light-key: "#C9C5BA"
  light-key-hi: "#ECE9E1"
  light-key-ink: "#1E1D1B"
typography:
  count:
    fontFamily: "-apple-system, BlinkMacSystemFont, SF Pro Text, Helvetica Neue, sans-serif"
    fontSize: "20px"
    fontWeight: 600
    lineHeight: 1
    letterSpacing: "-.02em"
    fontFeature: "tnum"
  palette:
    fontFamily: "-apple-system, BlinkMacSystemFont, SF Pro Text, Helvetica Neue, sans-serif"
    fontSize: "14px"
    fontWeight: 400
    lineHeight: 1
    fontFeature: "tnum"
  body:
    fontFamily: "-apple-system, BlinkMacSystemFont, SF Pro Text, Helvetica Neue, sans-serif"
    fontSize: "12px"
    fontWeight: 400
    lineHeight: "20px"
    fontFeature: "tnum"
  body-strong:
    fontFamily: "-apple-system, BlinkMacSystemFont, SF Pro Text, Helvetica Neue, sans-serif"
    fontSize: "12px"
    fontWeight: 600
    lineHeight: "20px"
    fontFeature: "tnum"
  label:
    fontFamily: "-apple-system, BlinkMacSystemFont, SF Pro Text, Helvetica Neue, sans-serif"
    fontSize: "11px"
    fontWeight: 400
    lineHeight: 1
    fontFeature: "tnum"
  key-label:
    fontFamily: "-apple-system, BlinkMacSystemFont, SF Pro Text, Helvetica Neue, sans-serif"
    fontSize: "10.5px"
    fontWeight: 400
    lineHeight: 1
    letterSpacing: "-.01em"
    fontFeature: "tnum"
  mono:
    fontFamily: "ui-monospace, SF Mono, Menlo, monospace"
    fontSize: "12px"
    fontWeight: 400
    lineHeight: 1.55
rounded:
  input-inline: "3px"
  item: "4px"
  control: "5px"
  tab: "6px"
  menu: "7px"
  sheet: "10px"
  command-field: "12px"
  key: "50%"
spacing:
  row: "20px"
  column-head: "22px"
  panel-foot: "24px"
  panel-bar: "28px"
  command-line: "30px"
  status-bar: "36px"
  title-bar: "38px"
  options-bar: "44px"
  key-column: "84px"
  panel-inset: "8px"
  bar-inset: "14px"
  gap-tight: "6px"
  gap-bar: "12px"
components:
  key:
    backgroundColor: "{colors.key}"
    textColor: "{colors.key-ink}"
    typography: "{typography.key-label}"
    rounded: "{rounded.key}"
    size: "34px"
  key-copy:
    backgroundColor: "{colors.go}"
    textColor: "{colors.go-ink}"
    rounded: "{rounded.key}"
    size: "34px"
  key-move:
    backgroundColor: "{colors.mv}"
    textColor: "{colors.mv-ink}"
    rounded: "{rounded.key}"
    size: "34px"
  key-trash:
    backgroundColor: "{colors.rm}"
    textColor: "{colors.rm-ink}"
    rounded: "{rounded.key}"
    size: "34px"
  lane-key:
    backgroundColor: "{colors.key}"
    textColor: "{colors.key-ink}"
    rounded: "{rounded.key}"
    size: "16px"
  button:
    backgroundColor: "{colors.key}"
    textColor: "{colors.key-ink}"
    typography: "{typography.body}"
    rounded: "{rounded.control}"
    height: "26px"
    padding: "0 12px"
  button-commit:
    backgroundColor: "{colors.cur}"
    textColor: "{colors.cur-ink}"
    typography: "{typography.body-strong}"
    rounded: "{rounded.control}"
    height: "26px"
    padding: "0 12px"
  button-go:
    backgroundColor: "{colors.go}"
    textColor: "{colors.go-ink}"
    typography: "{typography.body-strong}"
    rounded: "{rounded.control}"
    height: "26px"
    padding: "0 12px"
  button-mv:
    backgroundColor: "{colors.mv}"
    textColor: "{colors.mv-ink}"
    typography: "{typography.body-strong}"
    rounded: "{rounded.control}"
    height: "26px"
    padding: "0 12px"
  button-rm:
    backgroundColor: "{colors.rm}"
    textColor: "{colors.rm-ink}"
    typography: "{typography.body-strong}"
    rounded: "{rounded.control}"
    height: "26px"
    padding: "0 12px"
  row:
    textColor: "{colors.ink}"
    typography: "{typography.body}"
    height: "20px"
    padding: "0 8px"
  row-cursor:
    backgroundColor: "{colors.cur}"
    textColor: "{colors.cur-ink}"
    height: "20px"
  row-go:
    backgroundColor: "{colors.go-bg}"
    textColor: "{colors.go-t}"
    typography: "{typography.body-strong}"
    height: "20px"
  row-mv:
    backgroundColor: "{colors.mv-bg}"
    textColor: "{colors.mv-t}"
    typography: "{typography.body-strong}"
    height: "20px"
  row-rm:
    backgroundColor: "{colors.rm-bg}"
    textColor: "{colors.rm-t}"
    typography: "{typography.body-strong}"
    height: "20px"
  row-error:
    backgroundColor: "{colors.line}"
    textColor: "{colors.ink}"
    typography: "{typography.body-strong}"
    height: "20px"
  field:
    backgroundColor: "{colors.field}"
    textColor: "{colors.ink}"
    rounded: "{rounded.control}"
    height: "26px"
    padding: "0 8px"
  segment-on:
    backgroundColor: "{colors.key}"
    textColor: "{colors.key-ink}"
    rounded: "{rounded.item}"
    height: "24px"
    padding: "0 10px"
  menu:
    backgroundColor: "{colors.deck}"
    textColor: "{colors.ink}"
    rounded: "{rounded.menu}"
    width: "230px"
    padding: "4px"
  command-sheet:
    backgroundColor: "{colors.deck}"
    textColor: "{colors.ink}"
    rounded: "{rounded.sheet}"
    width: "520px"
---

# Design System: Commander

## Overview

**Creative North Star: "The Consequence Deck"**

Commander is a matte graphite case holding a darker work deck, with a warm off-white cursor band and a column of domed round keys between two file panels. Its one idea is that colour means exactly one thing: what happens when you press. Everything that is not an action stays neutral, so the three action colours can be read at a glance across a screen full of files.

The density is a machine's, not a web page's. Rows are 20px, type is 12px, and the panels hold everything the window can fit on one shared column grid. The keys are the only moulded objects; the rest is flat tone and hairlines. Pressing a key depresses it on screen and resolves its result as preview rows in the destination, so the consequence is visible before it is confirmed.

The system rejects both the sidebar-and-toolbar file manager and the terminal costume. It is a modern instrument with native Mac manners, in two themes that are the same object: graphite for dark, off-white for light.

**Key Characteristics:**
- Three action colours, each tied to a result and always paired with an icon or arrow
- Two themes of equal standing built from the same tokens
- 20px rows on one column grid, with panels sized in whole rows
- Status bar inline modes in place of confirmation dialogs
- Domed round keys as the only tactile material
- System type with tabular figures throughout

## Colors

A warm graphite neutral range carries three saturated action colours, and each action colour has a fill, a highlight, an ink for use on the fill, a text colour for tinted rows, and a wash.

### Primary
- **Copy Green** (#3FA34D): Copies and creates. Fills the Copy key, green run buttons, green progress bars and sync lane keys; washes destination preview rows for new files. Compress, Extract and Sync confirm with it because each writes new files.

### Secondary
- **Move Yellow** (#F2B705): Moves. Fills the Move key, the move run button and move progress; washes rows leaving the source panel.

### Tertiary
- **Trash Red** (#D8412F): Removes or overwrites. Fills the Trash key, the trash run button and any sync that sends files to Trash; washes rows going to Trash and destination rows a copy would replace.

### Neutral
- **Graphite Case** (#262523, light #DDD9CF): Window frame, tab strip, panel titles, footers, option bars.
- **Work Deck** (#1E1D1C, light #F3F1EB): Panel lists, status bar, menus and sheets.
- **Rim** (#000000, light #B9B4A7): Hard structural edges around the key column, title bar and status bar.
- **Hairline** (#3A3936, light #CFCABD): Inner dividers within panels, field strokes, and the error row band.
- **Ink** (#ECE8DE, light #1E1D1B): Primary text, marked rows, and headings in the status bar.
- **Dim Ink** (#A7A296, light #5E5A51): Secondary columns, labels, shortcuts, hints, and status bar messages.
- **Cursor Band** (#D9D5CA with ink #1A1917; light inverts to #2B2A27 with ink #F3F1EB): The cursor row, highlighted menu and palette items, the focus ring, text selection, and neutral commit buttons.
- **Field** (#161514, light #FBFAF6): Text inputs, sunk below the deck.
- **Neutral Key** (#3A3834 with highlight #55524C; light #C9C5BA with highlight #ECE9E1): Every key and button without an action colour.

### Named Rules

**The Press Means Rule.** Green copies or creates, yellow moves, red removes or overwrites. These colours mean nothing else anywhere in the interface.

**The Ink Verdict Rule.** Success text and validation messages are ink, not colour. A finished job, a bad name and a missing path all read in the neutral inks, and an error row is a hairline-toned band with bold ink.

**The Never Alone Rule.** An action colour always arrives with an icon or arrow, so the meaning survives without colour vision.

**The Same Object Rule.** Dark and light are two themes of equal standing, using the same tokens. Action fills, highlights and inks stay constant; only the neutrals, row text, washes and neutral keys change value. Neither theme is a derived afterthought.

## Typography

**Display Font:** none; the system stack does all the work
**Body Font:** System font (-apple-system, SF Pro Text, with Helvetica Neue fallback)
**Label/Mono Font:** System monospace (ui-monospace, SF Mono, with Menlo fallback)

**Character:** A single quiet face set small and tight, with tabular figures in every list so sizes and dates line up in columns. Weight, not size, does the sorting.

### Hierarchy
- **Count** (600, 20px, tracking -.02em): The selection count above the key column. The only large type in the window.
- **Palette** (400, 14px): The command palette input.
- **Body** (400, 12px, 20px line in rows): File rows, status bar text, buttons, menus and fields.
- **Body Strong** (600, 12px): Folder names, marked rows, preview rows, the current path segment, sorted column heads, and status bar headings.
- **Label** (400, 11px): Column heads, the size under the count, row notes and menu group labels.
- **Key Label** (400, 10.5px, tracking -.01em): Name and shortcut under each key. Removed below 760px window height.
- **Mono** (400, 12px, 1.55 line in the viewer): Masks, viewer text and the command line, nowhere else.

### Named Rules

**The Tabular Rule.** Every figure on screen is tabular, so columns of numbers never shimmer as they change.

**The Mono Is Literal Rule.** Monospace marks text the machine reads literally: masks, viewer text and the command line. It is not a flavour for the whole interface.

## Layout

The window is a fixed vertical stack: a 38px title bar with a centred 360px command field, the stage, a 36px status bar and a 30px command line. The stage is two equal panels with an 84px key column between them. Rename and compare keep the same three-column frame, swap the key column for a lane column of per-row keys, and add a 44px options bar above. Before, middle, after is the structure of every bulk screen.

A panel stacks 28px tabs, a 28px path bar, a 22px column head, its rows and a 24px footer. Every panel uses the same four columns: name takes the remaining width, then ext (96px), size (84px, right aligned) and modified (106px, right aligned). Find results widen the second column to 230px to hold the location.

Spacing is tight and small: 8px inset in panels, 14px in the window-wide bars, 12px between status items, 6px within a row's name cell. Nothing floats in generous space; leftover height stays at the foot of the list rather than being shared out.

The minimum window is 1000 by 600. At 1280px wide and below, option bars drop hints and shorten fields. At 760px tall and below, keys shrink from 34px to 30px and lose their labels.

**The Whole Row Rule.** Panels are sized in whole rows, 20px at a time, and never clip a row. The remainder of the height goes unused rather than showing part of a file.

**The One Grid Rule.** Both panels, and both sides of rename and compare, share one column grid, so the same fact sits at the same x position on each side.

**The One Fact Rule.** Each fact has one home: totals in the footer, free space in the path bar, the selection count over the keys. A run button may name what it will act on.

## Elevation & Depth

Depth is tonal first. The case sits above the deck, the field sinks below it, and rim and hairline edges do the separating. Shadows exist in exactly two roles: moulding the keys, and lifting the rare layer that floats over the window. The active panel is shown by a 2px cursor-coloured line inset at the top of its path bar, not by a raised surface.

### Shadow Vocabulary
- **Key dome** (`box-shadow: 0 2px 3px rgba(0,0,0,.45), inset 0 1px 0 rgba(255,255,255,.14)`): A key at rest, with a radial gradient lit from the upper left (38% 30%) from highlight to fill.
- **Key pressed** (`box-shadow: 0 0 1px rgba(0,0,0,.5), inset 0 2px 3px rgba(0,0,0,.35)`): A key held or pressed, translated down 2px.
- **Lane key** (`box-shadow: 0 1px 1px rgba(0,0,0,.4)`): The 16px per-row key.
- **Menu** (`box-shadow: 0 10px 26px rgba(0,0,0,.4)`): The context menu.
- **Sheet** (`box-shadow: 0 18px 42px rgba(0,0,0,.42)`): The command palette, over a 30% black scrim.

### Named Rules

**The Keys Are Moulded Rule.** Gradient and dome shading belong to keys. Panels, rows, bars and buttons stay flat.

## Shapes

Two silhouettes carry the system: the true circle of a key, and quietly softened rectangles for everything else. Corners stay small and grow only with the size of the layer: 3px on an inline row input, 4px on menu items and segments, 5px on buttons and fields, 6px on tab tops, 7px on the context menu, 10px on the sheet. The command field is a full 12px capsule. Rows and panels have square corners. Icons are 16-unit outlined strokes of 1.2 to 2 units; only the folder is solid.

## Components

Components are terse and tactile: a key feels pressed, a row feels printed, and everything else gets out of the way.

### Keys
The signature component and the primary action surface of the window.
- **Shape:** Domed circle (34px, 30px on short windows) with its name and shortcut beneath, in a column 80px wide.
- **Colour:** Copy, Move and Trash carry their action fills. View, Edit, New, Compress, Extract, Rename and Compare are neutral.
- **Order:** Compress and Extract, then View and Edit, then Copy and Move at the centre with New and Trash, then Rename and Compare. The Copy key is the primary action.
- **Press:** Depresses 2px with the pressed shadow over .14s on an exponential ease-out (`cubic-bezier(.16,1,.3,1)`). The key stays held while its preview is open, and its label turns ink.
- **Hover / Disabled:** Brightens 7% on hover; 38% opacity when disabled.
- **Above the keys:** The selection count, its size, and a direction arrow that mirrors with the active panel.

### Lane Keys
The key column becomes per-row direction keys in rename and sync: 16px domes in a 20px lane aligned to the rows. Green arrow syncs in that direction, red trash removes, and a neutral dash or equals shows skipped or identical with no dome. Rename lanes use neutral keys because nothing is copied, moved or removed. A key that changes state bounces briefly over .16s.

### File Rows
- **Default:** 20px, folders in 600, secondary columns in dim ink. A 6px tick left of the icon marks a row, with the whole row turning bold ink.
- **Cursor:** The cursor band in the active panel. In the inactive panel it becomes a 1px dim outline with no fill.
- **Preview:** Row wash with matching text in 600 and an icon that states the action: plus for new, alert for replaced. Preview rows arrive over .2s, rising 6px with the same ease-out.
- **Conflict:** A short note after the name says what happens, such as "replaces older".
- **Error:** Line-toned band, bold ink, alert icon.
- **Hidden:** Name and icon in dim ink.
- **Inline edit:** Rename and new folder swap in an 18px field with a cursor-coloured stroke, inside the row.

### Status Bar Modes
The status bar is where decisions happen. It replaces dialogs for confirmation, pattern marking, go to path and find. A mode holds an icon, a bold heading, live facts, its controls, then Cancel and the run button at the far right. Copy, Move, Trash, Compress and Extract confirm here with the source and destination still visible. Mark reports matches as you type, Go to reports a missing path in place, in neutral ink, and Find fills a results tab live. Jobs show progress here on a 4px bar in the action's colour. Transient messages replace the hint line for a few seconds.

### Buttons
- **Shape:** Softly squared (5px), 26px tall, 12px side padding, with the shortcut in its own legend after the label.
- **Neutral:** Key tone, for Cancel and Close.
- **Commit:** Cursor band and bold, for a run that copies, moves and removes nothing: Apply, Go, Rename, Keep results.
- **Action:** The action fill and matching ink, bold, for a run with that consequence. A sync that sends anything to Trash uses red.
- **Hover / Disabled:** Brightens 8%; 42% opacity when disabled.

### Segmented Choice
A case-toned tray (6px, 2px padding) of 24px segments. The selected segment takes key tone and a small shadow. Each option carries a one-letter shortcut, as in Replace, Skip and Keep both.

### Inputs / Fields
- **Style:** 26px, field tone, 1px hairline stroke, 5px radius, 8px side padding.
- **Focus:** 2px cursor-coloured ring offset 1px, the same for every control.
- **Error:** A neutral ink message beside the field, never a coloured stroke.
- **Command line:** Borderless mono input behind a `%` prompt.

### Navigation
Tabs are 24px with 6px top corners, dim on the case until selected, when they take the deck tone and join the panel. The path bar has back and forward chevrons, a bold current folder and free space at the right. Column heads are buttons; the sorted head turns bold ink.

### Menus and Palette
The context menu is 230px on the deck with 24px items, icons and right-aligned shortcuts, and the cursor band as its highlight. The command palette is a 520px sheet with a 40px input and 28px items, opened from the title bar command field or ⌘K. The viewer opens in the opposite panel, not a window.

### Native Translation
This record comes from an HTML prototype of a native SwiftUI and AppKit app, and native controls will differ in these places.
- **Open With:** The prototype shows a flat labelled group of apps inside the context menu. It becomes a real submenu.
- **Domed keys:** Drawn natively as a SwiftUI `ButtonStyle` with a radial gradient and shadows (`Commander/KeyColumn.swift`). The key's size, press travel and colour are settled; its rendering is not.
- **Window and menus:** The prototype's title bar and traffic lights stand in for the native window, and it has no Mac menu bar. The native chrome wins.
- **File panels:** `NSTableView` must hold the 20px rows and shared columns, and the app snaps panel height to whole rows.
- **Themes and motion:** Follow the system light, dark, contrast and reduced motion settings. With reduced motion, key press transitions and row arrival are removed.

## Do's and Don'ts

### Do:
- **Do** give every new action a colour by its result: green if it copies or creates, yellow if it moves, red if it removes or overwrites, and neutral otherwise.
- **Do** pair every action colour with an icon or arrow.
- **Do** write success and validation messages in ink, never an action colour.
- **Do** build new bulk screens as before, middle, after on the shared column grid, with per-row keys in the middle.
- **Do** ask for a decision in a status bar mode, with both panels still visible.
- **Do** preview the consequence as rows in the destination before confirming.
- **Do** check every screen in both themes, using the same tokens.
- **Do** size lists in whole 20px rows.
- **Do** keep motion to short exponential ease-out on key press and row arrival, and remove it under reduced motion.

### Don't:
- **Don't** use green, yellow or red for success, warnings, validation, status, branding or emphasis.
- **Don't** open a dialog for something a status bar mode can hold.
- **Don't** clip a row or stretch one to fill leftover height.
- **Don't** add a sidebar-and-toolbar layout, or anything that reads as a generic Finder clone.
- **Don't** dress the interface as a terminal; monospace stays on masks, viewer text and the command line.
- **Don't** treat light as a lesser theme or invent light-only tokens.
- **Don't** apply dome shading to anything but keys.
- **Don't** give a fact two homes.
- **Don't** loosen row height or spacing to make a screen feel airy.
