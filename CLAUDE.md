# CLAUDE.md

Native Nix package + NixOS module + VM test for RomM
(https://github.com/rommapp/romm). See README.md for the layout and the
version-bump runbook.

## Consumption contract

A downstream infra flake pulls `main` daily via automated `nix flake update`.
Keep `main` green: human changes go through a PR and must pass CI (package
build + VM test + formatting) before merge — never push directly to `main`
yourself.

Flake-input updates are the one exception: the weekly `update-flake.yaml`
workflow runs `nix flake update`, gates on `nix flake check -L` passing, and
pushes `flake.lock` straight to `main` — no PR. Treat that workflow's run log
as the CI evidence for those commits.

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
- Plain git, standard PR flow (except the automated weekly flake.lock push).
