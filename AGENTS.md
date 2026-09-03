# AGENTS.md

## Scope

These instructions apply to the entire repository. `subtool.sh` is the shipped CLI; keep changes portable across the Bash versions used by Linux and macOS.

## Development rules

- Preserve `set -euo pipefail` behavior and avoid Bash 4-only features such as associative arrays; macOS `/bin/bash` 3.2 is supported.
- Keep human-readable logs on stderr. Reserve stdout for command data that callers may capture.
- Build external commands with arrays. Never use `eval`, interpolate credentials into logs, or expose API responses that may contain secrets.
- Keep subtitle timestamps and block counts intact during translation. Failed or partial translations must fall back safely and clean temporary files.
- The `codex` provider must call `codex exec` with ephemeral sessions and a read-only sandbox. Require `--trust-codex-input` before invoking it because Codex tools may read local files. Use the Codex CLI configured model unless the user passes `--model`.
- Update help text, provider listings, completions, the generated man page, README examples, and tests together when the CLI surface changes.

## Verification

Run before committing:

```bash
/bin/bash tests/run_tests.sh
bash -n subtool.sh tests/run_tests.sh
shellcheck -x -S warning subtool.sh
git diff --check
```

Use Conventional Commits. Releases are generated from `main` by semantic-release; do not edit `VERSION` manually.
