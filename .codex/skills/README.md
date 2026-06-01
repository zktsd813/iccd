# Repo-Local Codex Skills

This directory keeps ICCD-specific Codex skills in the repository so other
machines can use the same workflow instructions.

Install on a machine by copying or symlinking the skill directory into
`$CODEX_HOME/skills`, for example:

```bash
mkdir -p "${CODEX_HOME:-$HOME/.codex}/skills"
ln -s "$(pwd)/.codex/skills/migration-friendly-kernel" \
  "${CODEX_HOME:-$HOME/.codex}/skills/migration-friendly-kernel"
```

The repo-local copy is the source of truth. Do not keep a divergent personal
copy under `$HOME/.codex/skills`.
