# Contributing to jTerm

Thank you for contributing. jTerm is an independent Ghostty-derived terminal emulator. Submit jTerm issues and pull requests to [Outperform-Ventures/jterm](https://github.com/Outperform-Ventures/jterm).

## Reporting bugs

Include your operating system, Zig version, jTerm revision, reproduction steps, and expected versus actual behavior. Use a minimal configuration and synthetic terminal output where possible. Remove credentials, shell history, personal paths, and other sensitive content from logs or screenshots.

## Making changes

1. Start from `main` and create a focused branch.
2. Build with `zig build`; use the build system rather than invoking Xcode directly.
3. Add regression tests for behavior changes and run the relevant tests.
4. Format changed Zig files with `zig fmt` and follow the surrounding Swift style.
5. Open a pull request explaining the change and validation performed.

Run `zig build test` for the full suite, including native tests on macOS. Use `zig build test -Dtest-filter=<name>` to run matching Zig tests separately. Native application changes need native validation; core-test success alone is insufficient.

Use isolated configuration and sockets for remote-control tests. Do not run tests against an unrelated active terminal session. Review generated logs before sharing them.

## Upstream changes

Preserve upstream license notices and keep jTerm-specific changes focused. Changes intended for Ghostty itself should follow that project's current contribution guidelines. This repository does not use Ghostty's contribution approval or automation systems.

## Review

Submit changes you understand and can explain. If you use code-generation tools, review their output and verify behavior before submitting. Do not include proprietary code, private conversation records, credentials, or generated build artifacts.
