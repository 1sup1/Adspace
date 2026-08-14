# Project instructions

- Use Homebrew only for system-level packages and declare them in `Brewfile`.
- Use mise for language runtimes and project tools; pin versions in `mise.toml`.
- Run project commands through mise with `mise exec -- ...` or `mise run ...`.
- Do not install project dependencies globally.
- After changing the development environment, verify it with `mise run setup` and `mise run check`.
- Search for skills with `mise exec -- npx --yes skills@latest find <query>`.
- Install additional skills for this project only. Do not use `-g` or `--global`.
- Target Codex explicitly: `mise exec -- npx --yes skills@latest add <source> --skill <name> --agent codex --yes`.
- Keep project-installed skills and their lock metadata in version control.
