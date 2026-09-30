# Changelog

All notable changes to this project will be documented in this file.

## [1.2.0] - 2026-09-30

### Added
- **Hint** button, working in a whole coloured path rather than in cells. Two taps: the first says which pair's route is not right yet, the second draws it end to end. Revealing a single cell would leave the route half-drawn.

### Fixed
- Each path now carries its pair's digit in every cell it crosses, not only at
  its two endpoints. The six path shades are spaced 34/255 apart -- about two
  steps on a 16-level e-ink panel -- so two neighbouring routes were told apart
  by shade alone, which on a reflective screen often was not possible.
- The wrong-cell border was drawn in COLOR_GRAY, which is path colour 5's own
  shade, so it was invisible against that path. It is black now.

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
