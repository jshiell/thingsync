# AGENTS.md

## Verify gate

thingsync is mid-port from Python to a native Swift CLI (see `plan.md`).
Two regimes apply depending on where the port stands:

- **While the Python and Swift implementations live side by side** (current
  state, through milestone M9.5 of the port plan): both of the following
  must pass before work is considered done.

  ```sh
  uv run pytest
  swift test
  ```

- **After the Python implementation is deleted** (M9.5 onward): only the
  Swift gate applies.

  ```sh
  swift build -c release
  swift test
  ```

No linter is configured for either language at this time.
