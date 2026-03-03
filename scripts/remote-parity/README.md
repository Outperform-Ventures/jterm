# Remote Parity Harness

## Commands

- Validate vector schema:
  - `python3 scripts/remote-parity/validate_vectors.py`
- Initialize/refresh coverage tracker:
  - `python3 scripts/remote-parity/coverage.py init --merge`
- Check coverage summary:
  - `python3 scripts/remote-parity/coverage.py check`
- Enforce 100% coverage completeness:
  - `python3 scripts/remote-parity/coverage.py check --require-complete`
- Run protocol wire-parity checks (DCS/encrypted envelope/server behavior):
  - `python3 scripts/remote-parity/protocol_parity.py`
- Run CLI help/option parity matrix checks against spec lock:
  - `python3 scripts/remote-parity/cli_parity.py`
- Run parity fixtures/corpus against already-running kitty + jterm:
  - `python3 scripts/remote-parity/certify.py --mode all`
- Spawn kitty + jterm for a local parity run:
  - `python3 scripts/remote-parity/certify.py --mode all --spawn-apps`
- Enforce zero known gaps:
  - `python3 scripts/remote-parity/certify.py --mode all --strict-known-gaps`
- Run phase-only behavioral suite:
  - `python3 scripts/remote-parity/certify.py --mode phases --spawn-apps --strict-known-gaps`
- Run all gates (coverage/protocol/CLI/behavior/build/tests):
  - `python3 scripts/remote-parity/gates.py`
- Run the full feature suite (strict gates + explicit command-by-command replay):
  - `python3 scripts/remote-parity/full_feature_suite.py`

## Notes

- The harness compares kitty and jterm command outcomes operation-by-operation.
- Marked `known_gap` fixtures are treated as expected failures unless
  `--strict-known-gaps` is set.
- `test/remote/parity/phases/` contains explicit phase 0-10 fixture coverage.
- Default paths are configured for macOS app-bundle kitty and local `jterm` build.
