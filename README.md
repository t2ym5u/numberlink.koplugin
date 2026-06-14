# numberlink.koplugin

A Numberlink plugin for [KOReader](https://github.com/koreader/koreader).


## Screenshot

*(Screenshot to be added.)*

## Rules

Connect matching number pairs with continuous horizontal/vertical paths. Paths cannot cross or share cells. Every cell of the grid must be covered by exactly one path.

## Concept

Connect each pair of matching numbers on the grid with a continuous path.
Paths may not cross or branch, and every cell in the grid must be covered
by exactly one path.

## Features

- **Multiple grid sizes** — 5×5, 7×7, 9×9, 10×10
- **Three difficulty levels** — Easy (fewer pairs), Medium, Hard
- **Path drawing** — drag or tap-to-extend to draw paths
- **Auto-clear** — drawing over an existing path segment removes it from that point
- **Check** — highlights uncovered cells and crossing paths
- **Reveal solution** — shows the full solution
- **Undo** — step back one path segment at a time
- **Auto-save** — game state saved and restored on next launch

## Controls

| Action | How |
|--------|-----|
| Start a path | Tap a numbered cell |
| Extend a path | Tap adjacent cells in sequence |
| Retract a path | Tap the last segment again |
| Clear a full path | Long-press any segment of that path |
| Undo last segment | Tap **Undo** |
| Check progress | Tap **Check** |
| New game | Tap **New game** |
| Change grid size | Tap **Grid** |
| Change difficulty | Tap **Diff** |
| Show rules | Tap **Rules** |

## Why e-ink friendly?

Paths are rendered as thick lines between cell centres — static between taps,
requiring only a small screen region to be refreshed per interaction.

## License

GPL-3.0
