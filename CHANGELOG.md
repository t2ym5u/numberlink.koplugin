# Changelog

All notable changes to this project will be documented in this file.

## [1.1.10] - 2026-07-31

### Fixed
- `board_widget.lua` referenced Blitbuffer color constants that don't
  exist (COLOR_GRAY_8 / COLOR_GRAY_A / COLOR_GRAY_C), which evaluated to `nil` and crashed the
  color-comparison in `paintTo()` as soon as the corresponding
  highlight was drawn. Now uses the correct constant name(s)
  (COLOR_DARK_GRAY / COLOR_GRAY / COLOR_LIGHT_GRAY).

## [1.1.7] - 2026-07-28

### Fixed
- Generated puzzles were severely under-constrained: the color density
  was far too low for the given endpoints to pin down a unique solution
  (measured 0% actually unique). Raised the color density and added a
  uniqueness solver to verify each puzzle before accepting it. Every
  puzzle now ships with a guaranteed unique solution at every size and
  difficulty.
