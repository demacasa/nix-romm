# CLAUDE.md

Native Nix package + NixOS module + VM test for RomM
(https://github.com/rommapp/romm). See README.md for the layout and the
version-bump runbook.

## Consumption contract

A downstream infra flake pulls `main` daily via automated `nix flake update`.
Keep `main` green: every change goes through a PR and must pass CI (package
build + VM test + formatting) before merge. Never push directly to `main`.

PRs opened by the update-flake workflow do not trigger the CI workflow
(GitHub does not fire `pull_request` for GITHUB_TOKEN-created PRs); that
workflow runs `nix flake check` itself before opening the PR — treat its run
log as the CI evidence.

## Commands

- `nix fmt` — format (treefmt; `workspace/` is excluded, keep it verbatim
  from upstream)
- `nix flake check` — build + VM test + formatting (VM test needs KVM)
- `nix build '.#romm'` — package only
- `nix eval --raw '.#checks.x86_64-linux.romm.drvPath'` — eval-only check
  when KVM is unavailable

## Version bumps

Follow the runbook in README.md exactly, including reading the release notes
of every skipped version. Bumps go through a PR; CI runs the VM test.

## Conventions

- No code comments unless explicitly asked. Existing comments: leave alone,
  except delete or correct any your change makes false.
- Quote flake refs containing `#` (`nix build '.#romm'`).
- Plain git, standard PR flow.
