# Agent Development Guide

A file for [guiding coding agents](https://agents.md/).

- All commands must have a `--dry-run` option that is default on.
- Commands that do not modify external state don't need a `--dry-run` option.
- The order of definitions in Nu files should be:
  (1) CLI commands (exported, sorted alphabetically)
  (2) Helper commands (exported)
  (3) Helper commands (non exported)
- Verify help output using `use <module> *; help <def>`. Everything
  must have human-friendly help output.
- See `VOUCHED.example` for an example vouch file.
