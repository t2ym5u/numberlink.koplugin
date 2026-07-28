# Changelog

All notable changes to this project will be documented in this file.

## [1.1.7] - 2026-07-28

### Fixed
- Generated puzzles were severely under-constrained: the color density
  was far too low for the given endpoints to pin down a unique solution
  (measured 0% actually unique). Raised the color density and added a
  uniqueness solver to verify each puzzle before accepting it. Every
  puzzle now ships with a guaranteed unique solution at every size and
  difficulty.
