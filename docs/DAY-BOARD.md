# Stickies+ day board

Design notes, 12 October 2026. How the code works is in [HOW-IT-WORKS.md](HOW-IT-WORKS.md).

## The idea

Every theme or project has its own sticky of checkboxes, same as now. One **main sticky** collects what needs doing, pulled from all stickies by date. It's mostly a **Today** board: open it and see what today needs.

## Dates on tasks

- You type the date in words at the end of the line. English mostly, sometimes Czech:
  - `today`, `tomorrow`, `fri`, `next week`, `14 oct`, `14.10.`
  - `dnes`, `zítra`, `pátek` / `pá`, `příští týden`
  - an optional time: `fri 15:00`
- The date shows small and faded at the end: `☐ send mix to anna      · Fri`
- It stays plain text you can edit anywhere, the main sticky included. Click next to it, delete, and retype. That's also how you move a task to another day.
- **Repeating:** `every day`, `every mon`, `každý den`. The task shows up fresh each day, and ticking it only ticks that day's copy.

## Main sticky

It works like any other sticky (color, move, collapse…), with sections:

```
▾ Today                                   (always open)
  ☐ answer label email   2 days late · moved 3×     ← overdue: red, on top
  14:00  team meeting                               ← calendar, can't tick
  ☐ send mix to anna                    music     ← today's tasks + where they live
▸ Tomorrow  4                             (folded, includes tomorrow's events)
▸ This week  7
▸ Later  12
```

- **Overdue tasks** sit at the top of Today: red, showing how late they are. They stay until you tick them or move the date. Moving the date takes a task out of red, but it keeps a `moved 3×` mark.
- **Mirrors, not copies:** a task lives in its theme sticky. Ticking or editing it in main does the same in its theme sticky. Ticked tasks fade, and after 13 h they go to the done pile of the sticky they live in.
- **Typing a new task in main:** `send mix #music` goes into the music sticky. Without a `#` it goes into your **random pile** sticky (the one called "random pile" / "random"). Either way it stays visible in main.
- Tasks without a date don't appear in main.
- Today is always open. The other sections start folded and stay how you leave them.

## Getting red

- Your day ends at **2:00**.
- A task dated today looks normal until 20:00, then warms up until it's full red at 2:00.
- A task with a time turns red over the 6 hours before that time.
- After that it's overdue: top of Today, full red.

## Subtasks and folding

- **Tab** indents a checkbox under the one above it.
- The parent shows progress (`1/3`) and ticks itself when the last subtask is done. Ticking the parent ticks all its subtasks.
- Subtasks follow their parent's date. A subtask with its own date shows up in main on its own, with the parent's name next to it.
- Any line with indented lines under it gets a ▸ / ▾ to fold them, in every sticky.

## Extras

- **Calendar:** today's timed events (with times) and all-day events at the top of Today. Tomorrow's events go in Tomorrow. Events come from Apple Calendar (including Google accounts added there) and can't be ticked. Nothing in the calendar gets changed, and it needs a one-time permission.
- **Menu bar:** a small count of tasks left today, red when something is overdue. Click it to bring the main sticky forward.
- **Opens at login.**

## Build order

Each step is usable before the next one starts.

1. **Dates on tasks:** recognizing typed dates, the faded date, warming to red, "late".
2. **Subtasks and fold arrows.**
3. **Main sticky:** Today with overdue on top, Tomorrow / This week / Later, mirroring and editing back into theme stickies, `#sticky`, random pile.
4. **Repeating tasks** and the `moved N×` mark.
5. **Calendar events, menu bar count, open at login.**

## Round 2 (12 Oct 2026, after using it)

- Today is grouped by sticky: a thin bar in the sticky's color down its tasks, the sticky's name in its color on the group's first line, a little space between groups, earliest first inside a group, groups ordered by their most urgent task. Clicking a sticky's name folds its group into one line. Late tasks stay on top, across stickies.
- The board's title is the date ("Monday 12 October"), its top bar is a bit taller (18 pt instead of 12), and Tomorrow / This week / Later shrink into one clickable line at the bottom.
- Done counter: a punch card. One hole per task of the day; each finished one is punched in its sticky's color, in the order you finished them. Picked over a gradient (too slick) and over squares (felt like a form).
- Ticking anywhere: the strike line draws in uneven steps, then a small pixel sparkle, about 12 frames a second on purpose.
- Tasks sort themselves by date inside each block of a sticky.
- The board comes to the front once a day at 8:00 (or the first wake after), without taking the keyboard.
- Calendar on the board: three weeks from this Monday, a mark per task in its sticky's color, click a day to list it.

## Decisions made while building

- Tasks redden in their theme stickies too, not only in main.
- "This week" runs to Sunday.
- Today can't be folded at all (it's always open).
- A ticked repeating task stays ticked until the day ends (2:00). Then it goes to the done pile and comes back open.
- When you leave a line, a relative date ("fri", "zítra") is rewritten to a fixed one ("Fri 16 Oct"), so "tomorrow" doesn't slide forward every day.
- A new task typed under This week without a date gets that Sunday. Under Later, it gets next Monday.
- Section titles and calendar events on the board can't be edited. A mirrored task on the board can't lose its box or be indented there. Do that in its own sticky.
- Deleting a task's line on the board deletes the task in its sticky. Undo it in that sticky.
- The board hides when you close it (⌘W or its close box). Window › Day Board (⇧⌘B) or the menu bar count brings it back.

## Technical notes

- Mirroring is the hard part: every task gets a hidden ID so edits in main land on the right line of the right sticky.
- The main sticky's sections are rebuilt from all stickies whenever something changes, plus at 2:00 and on wake.
