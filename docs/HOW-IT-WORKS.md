# How Stickies+ works

A walk through the code, in the order I'd read it. It's Swift and AppKit, the same Mac framework Apple's Stickies is built on. There's no Xcode project. Swift Package Manager builds it (`swift build`), and `scripts/build.sh` wraps the result into `build/Stickies+.app`.

About 4,200 lines in 15 files. One file, `ChecklistTextView.swift`, is a third of it, because that's where every line of a note gets its behavior.

## The picture

```
 ~/Library/Application Support/Stickies+/Notes/<id>/
   content.rtfd   the text (TextEdit can open it)
   note.json      color, position, done pile, and what each line carries
         │
         │ NoteStore.loadAll()
         ▼
 AppDelegate ──── one StickyController per sticky ──── StickyWindow
     │                     │                              ├─ SpineView        (12 pt top bar)
     │                     │                              ├─ ChecklistTextView (the text)
     │                     │                              └─ DonePileView      (the back side)
     │                     │ onChange
     ▼                     ▼
 BoardController ── BoardBuilder ── the day board's text (one more sticky, isBoard = true)
```

Three targets live in `Package.swift`. `StickiesPlusKit` is all the code. `StickiesPlus` is the 7-line `main.swift` that starts it. `StickiesPlusTests` holds the tests: 58 that always run, plus 3 that only draw preview images or check a copy of real notes when you ask for them.

## The files

**`AppDelegate.swift`** runs the app. On launch it loads every note, imports Apple Stickies the first time, creates the day board if there isn't one ([setUpBoard](../Sources/StickiesPlusKit/AppDelegate.swift:133)), and starts a 30-second timer ([tickAll](../Sources/StickiesPlusKit/AppDelegate.swift:99)). Each tick sweeps 13-hour-old ticks into done piles and asks the board to refresh. Menu actions that aren't about one sticky (New Note, Arrange By, Day Board, Open at Login) land here.

**`StickyController.swift`** is one sticky. It builds the window, owns the text view, saves after changes (0.6 s after the last one), collapses, zooms, flips to the done pile ([runFlip](../Sources/StickiesPlusKit/StickyController.swift:336) takes a picture of both sides and rotates a layer between them), and deletes to the Trash. When its text changes it calls `onChange`, which is how the board finds out.

**`StickyWindow.swift`** is Stickies' look. The window has no title bar. [SpineView](../Sources/StickiesPlusKit/StickyWindow.swift:59) draws the 12 pt bar and its tiny buttons at the positions read out of Stickies' own `SNDocument.nib`. Without a title bar macOS gives you no resizing, so [ResizeHandle](../Sources/StickiesPlusKit/StickyWindow.swift:183) adds 4 pt invisible strips along the edges.

**`ChecklistTextView.swift`** is the heart. It's an `NSTextView` (the standard Mac text editor) with checkboxes, subtasks, folding, dates and red drawn in. The next section explains how.

**`TaskText.swift`** lists what a line can carry (checkbox, id, level, fold, date, times moved, board role) and keeps it consistent.

**`TaskDates.swift`** reads dates. [DateParser](../Sources/StickiesPlusKit/TaskDates.swift:158) looks at the last few words of a line and tries to read them as "fri", "16 oct", "zítra 15:00" or "every mon". [TaskClock](../Sources/StickiesPlusKit/TaskDates.swift:91) holds your 2:00 day end and the 6-hour warm-up, and `Urgency` turns a date plus the current time into calm, warming (0 to 1) or overdue.

**`BoardBuilder.swift`** and **`BoardController.swift`** are the day board. The next section covers them too.

**`NoteStore.swift`** saves and loads, imports Apple Stickies, and holds `AppSettings` (13 hours, default color and font).

Smaller ones: `Palette.swift` (the 11 colors, Stickies' six copied from its asset catalog), `Scrollers.swift` (the thin note-colored scroller), `DonePileView.swift` (the back side), `MainMenu.swift` (every menu item and shortcut, taken from Stickies' `MainMenu.nib`), `Integrations.swift` (calendar, menu bar count, login item).

## Ideas worth learning

### 1. A line remembers things through attributes on its text

Mac text is an `NSAttributedString`. Every character can carry a dictionary of extras: font, color, and anything else you invent. Stickies+ invents keys like `.checklist` (0 = open box, otherwise the tick time) and `.taskLevel` (subtask depth), all listed at the top of [TaskText.swift](../Sources/StickiesPlusKit/TaskText.swift).

The rule is that the first character of a line decides for the whole line. After every edit, [normalizeParagraphs](../Sources/StickiesPlusKit/TaskText.swift:119) copies the first character's values across the line and gives every checkbox a unique id. That's why splitting a line in two with Return gives the second half a fresh id instead of a copy.

### 2. Draw on top, never change the text

The boxes, strike-through lines, ▸ arrows, "1/3", "2 days late" and the sticky names on the board aren't text. [draw(_:)](../Sources/StickiesPlusKit/ChecklistTextView.swift:150) paints them after the normal text drawing. The stored text stays plain rich text that TextEdit can still open.

Colors work the same way. The layout manager (the part of the text system that turns characters into positioned glyphs) asks a delegate for extra colors while it draws ([this function](../Sources/StickiesPlusKit/ChecklistTextView.swift:376)). That's where ticked lines fade, dates go gray, tasks warm to orange and red, and black text turns light on Graphite and Charcoal. It runs at draw time, so the color is already right in the frame you type a key.

### 3. Folding hides glyphs, not text

When you fold a line, its subtasks are still in the text. [computeHiddenRanges](../Sources/StickiesPlusKit/ChecklistTextView.swift:427) works out which characters are folded away. Then another layout manager callback ([shouldGenerateGlyphs](../Sources/StickiesPlusKit/ChecklistTextView.swift:459)) marks their glyphs `.null`, so they take no space. The newline of the folded line is hidden too, which pulls the next visible line up. The caret skips over hidden text (`setSelectedRanges`).

### 4. Dates are read from the text every time

There's no hidden date field. The date is the words at the end of the line, so you can retype it anywhere. One wrinkle: "tomorrow" means a different day tomorrow. So when the caret leaves a line, [commitTask](../Sources/StickiesPlusKit/ChecklistTextView.swift:1039) rewrites relative words into a fixed date ("fri" becomes "Fri 16 Oct", in 10 pt). It also stores that date in `.taskDue`. If the next commit finds a different date and the old one was already late, it adds 1 to `.taskMoved`. That's the "moved 3×".

### 5. Ticking walks up and down the tree

Subtasks are just deeper levels. [toggleCheckbox](../Sources/StickiesPlusKit/ChecklistTextView.swift:641) ticks the line and everything nested under it, then walks up through the parents. A parent whose subtasks are all done gets ticked, and one with an open subtask gets unticked. Every change goes through `shouldChangeText` / `didChangeText`, which is how AppKit registers undo and tells the controller to save.

### 6. The day board is rebuilt, not edited in place

[BoardBuilder.build](../Sources/StickiesPlusKit/BoardBuilder.swift:141) is a pure function: stickies + calendar events + the time in, board text out. Each task line on the board carries the original task's id. A dictionary (`mirrors`) remembers what each line looked like when the board was built.

When you change the board, [boardTextDidChange](../Sources/StickiesPlusKit/BoardController.swift:132) compares every line with its mirror and sends only the differences back to the task's own sticky: new text, a tick, a fold, a moved date, or a deletion. Then the board gets rebuilt from the stickies. While you're typing on the board, rebuilding waits until you leave the line, so it never yanks the text from under the caret. New lines you type are filed by [fileLine](../Sources/StickiesPlusKit/BoardController.swift:216): `#tag` picks the sticky, otherwise [randomPile](../Sources/StickiesPlusKit/BoardController.swift:270), and a line without a date gets the day of the section you typed it in.

### 7. Saving: RTFD plus a small JSON

RTF has nowhere to keep custom attributes, so [save](../Sources/StickiesPlusKit/NoteStore.swift:129) writes two files. The text goes in `content.rtfd`. The per-line extras go in `note.json` by line number ([checklistMarks](../Sources/StickiesPlusKit/ChecklistTextView.swift:117) writes them, [applyMarks](../Sources/StickiesPlusKit/ChecklistTextView.swift:130) puts them back). Both are written from the same moment, so the line numbers always match.

### 8. Never touch a line in the middle of a keystroke

The "letters under each other" bug taught this one. AppKit keeps track of what changed during a keystroke and puts the caret at the end of it. If the code changes anything else on the line during that keystroke, even removing an attribute that isn't there, the "changed" part grows to the whole line. The caret then lands after the line's Return, at the start of the next line, and every letter goes one line further down.

So the code follows three rules:
- The cleanup in [normalizeParagraphs](../Sources/StickiesPlusKit/TaskText.swift:119) only edits a line that really needs it.
- What you type next always carries the line's current state (`didChangeText` re-syncs it), so the cleanup has nothing to fix.
- Work triggered by moving the caret, like fixing a date, waits until the keystroke is over (`commitIfLeftLine` queues it).

`TypingFuzzTests` drives thousands of random edits and checks that every typed letter lands right after the previous one.

### 9. The board's extras are drawn, not written

The punch card, the calendar grid, the color bars and the sparkle are drawn by the text view like the checkboxes. The board's text only carries a little data for them: the punch card line holds "purple,yellow|3" (finished tasks' colors in order, then how many are open), the calendar line holds one "2026-10-15;yellow,purple;0;0" per day. Clicks on them are mapped back in `boardClick(at:)`.

One gotcha: after `super.draw`, NSTextView leaves drawing clipped to the text area, so anything in the left margin (fold arrows, color bars) was cut off until `draw(_:)` reset the clip.

The finish animation keeps a start time per ticked task and a timer redraws about 24 times a second. Each frame picks the step it's in, so the motion stays choppy on purpose.

### 10. Tests fake the clock

Anything time-based reads `now()` and a `calendar` instead of the real clock. Tests set them to Monday 12 October 2026, 14:00, Prague, and move time forward by changing a variable. That's how the 13-hour sweep, the 20:00 warm-up and "3 days late" get tested in milliseconds. The tests drive the real text view with the same calls the keyboard and mouse make (`insertText`, `insertNewline`, `insertTab`, `mouseDown`).

```bash
swift test                                        # everything
swift test --filter BoardTests                    # one group
RENDER_DIR=/tmp swift test --filter RenderBoard   # draws board.png so you can see it
```

## Where to change things

| You want to change | Look at |
|---|---|
| 13 hours before the done pile | `AppSettings.doneDelay` in [NoteStore.swift](../Sources/StickiesPlusKit/NoteStore.swift:64) |
| Day ends at 2:00, red over 6 hours | [TaskClock](../Sources/StickiesPlusKit/TaskDates.swift:91) |
| Date words (add Italian?) | `DateWords` in [TaskDates.swift](../Sources/StickiesPlusKit/TaskDates.swift:138) |
| The orange and red | [urgencyColor](../Sources/StickiesPlusKit/ChecklistTextView.swift:354) and `redColor` just above it |
| Note colors | [Palette.swift](../Sources/StickiesPlusKit/Palette.swift) |
| Board sections and their order | [BoardBuilder.build](../Sources/StickiesPlusKit/BoardBuilder.swift:141) |
| What counts as the random pile | [randomPile](../Sources/StickiesPlusKit/BoardController.swift:270) |
| Keyboard shortcuts | [MainMenu.swift](../Sources/StickiesPlusKit/MainMenu.swift) |
| What the Return key does | [insertNewline](../Sources/StickiesPlusKit/ChecklistTextView.swift:788) |

After a change: `swift test`, then `./scripts/build.sh`, then quit Stickies+ and open `build/Stickies+.app` again.
