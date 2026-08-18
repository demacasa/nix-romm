# RomM (native package)

Native NixOS build of [RomM](https://github.com/rommapp/romm). The backend
Python closure is built from upstream's `uv.lock` via uv2nix, the Vue
frontend and the RomPatcher.js helper via `buildNpmPackage`. Ships a full
NixOS module with an upstream-equivalent nginx serving layer, and every
change is gated by a VM test that boots the full stack and runs migrations
on a fresh DB.

Originally derived from
[rommson/nix-romm](https://github.com/rommson/nix-romm), substantially
reworked.

Intentionally omitted relative to the upstream Docker image: EmulatorJS/Ruffle
(in-browser play) and RAHasher (RetroAchievements hashing — degrades
gracefully to a logged error).

## Usage

```nix
{
  inputs.nix-romm = {
    url = "github:demacasa/nix-romm";
    inputs.nixpkgs.follows = "nixpkgs";
  };
}
```

Import `nix-romm.nixosModules.default` into a host and configure:

```nix
{ inputs, config, ... }:
{
  imports = [ inputs.nix-romm.nixosModules.default ];

  services.romm = {
    enable = true;
    port = 8081;
    database.createLocally = true;
    apiKeyFile = config.sops.secrets.romm_env_file.path;
    nginx = {
      enable = true;
      port = 8083;
    };
  };
}
```

`apiKeyFile` is a systemd `EnvironmentFile` that must define at least
`ROMM_AUTH_SECRET_KEY` and `DB_PASSWD`, plus any scraper keys
(`IGDB_CLIENT_ID`, `MOBYGAMES_API_KEY`, ...). The nginx user needs read
access to `services.romm.dataDir`. Only x86_64-linux is tested.

## Updating to a new upstream release

All version-specific pins live at the top of `package.nix`: `version`,
`srcHash`, `frontendNpmDepsHash`, `romPatcherNpmDepsHash`.

1. Read the release notes for every version being skipped
   (`https://github.com/rommapp/romm/releases`). Look for warnings (MariaDB
   privileges, proxy caching), new env vars, and new subsystems.

2. Refresh the vendored workspace from the upstream tag:

   ```sh
   git clone --depth 1 --branch <tag> https://github.com/rommapp/romm /tmp/romm
   cp /tmp/romm/pyproject.toml /tmp/romm/uv.lock /tmp/romm/.python-version workspace/
   ```

   workspace/ is excluded from formatting — the copies stay verbatim.

3. Bump the pins in `package.nix`:

   ```sh
   nix flake prefetch "github:rommapp/romm/<tag>" --json        # srcHash
   nix run 'nixpkgs#prefetch-npm-deps' -- /tmp/romm/frontend/package-lock.json
   nix run 'nixpkgs#prefetch-npm-deps' -- /tmp/romm/backend/utils/rom_patcher/package-lock.json
   ```

   Check `python = pkgs.python3XX` still matches `workspace/.python-version`
   and `nodejs` matches `frontend/package.json` `engines.node`.

4. Diff upstream for drift the package must track. The build fails loudly on
   most of it (`substituteInPlace --replace-fail`, missing entry scripts), but
   check deliberately:
   - `docker/Dockerfile`: new runtime binaries or build stages.
   - `docker/init_scripts/init`: process list and flags — each
     `start_bin_*` maps to a `$out/bin/romm-*` wrapper in `package.nix`
     (gunicorn args, `rq worker` flags, watchfiles targets).
   - `backend/utils/archives.py`: the hardcoded `/usr/bin/7zz` and
     `/usr/bin/bsdtar` constants patched to store paths.
   - `docker/nginx/templates/default.conf.template`: location blocks and
     cache headers, mirrored in the nginx section of `module.nix` and
     asserted by `checks/vm.nix`.
   - Alembic chain continuity when upstream squashes migrations: the
     currently deployed head must still be present under
     `backend/alembic/versions/` in the new tag.
   - RomM's anonymous API surface, tracked in `api-auth.nix` — the VM test
     fails the build if it drifts. See "API auth surface" below.

5. Build and test (the VM test boots the full stack and runs migrations on a
   fresh DB):

   ```sh
   nix build --no-link '.#romm'
   nix build --no-link '.#checks.x86_64-linux.romm'
   ```

   (note: needs KVM; otherwise open a PR and let CI run it.)

   New Python deps occasionally need `pyprojectOverrides` fixups in
   `package.nix` (sdists missing setuptools, native libs for packages without
   a usable wheel) — the venv build error names the package.

6. Migrations are effectively one-way; if your deployment auto-follows this
   repo, dump the DB before merging a version bump:

   ```sh
   # on the host:
   mysqldump romm | zstd > /root/romm-pre-<tag>.sql.zst
   ```

## API auth surface

The repo owner's internet-facing reverse proxy blocks anonymous requests to
RomM's API at the edge, except for an explicit allowlist of endpoints RomM
itself treats as anonymous (login, token exchange, device pairing, ...).
That allowlist has to track RomM's actual code across version bumps, or a
newly-added anonymous endpoint gets a spurious 401 at the edge (this
happened with the device-auth endpoints).

`api-auth.nix` is the single source of truth for that allowlist, exported as
`lib.apiAuth` for consumers to build their edge config from:

```nix
{
  edgeExempt = [ ... ];    # anonymous endpoints an internet-facing proxy should let through
  knownAnonymous = [ ... ]; # anonymous endpoints deliberately NOT edge-exempted
}
```

Both lists contain path patterns for RomM's `/api/*` surface. `edgeExempt`
is what a proxy consumes directly. `knownAnonymous` documents anonymous
endpoints that stay behind the edge on purpose (e.g. account creation,
password reset) — they exist so the drift check below has somewhere to put
every anonymous route, not just the ones meant to be edge-exempt. Their
union must exactly equal RomM's anonymous API surface: every anonymous
route is in exactly one of the two lists (or covered by a glob in one of
them), and every entry matches at least one real anonymous route.

A pattern's trailing `*` matches any suffix, including further `/`
segments (e.g. `/api/client-tokens/pair/*` covers
`/api/client-tokens/pair/{code}/status`). Path-parameter segments
(`{code}`, `{source}`, ...) are normalized to a fixed `{param}` placeholder
before matching, in both the declared patterns and the live spec paths, so
a param rename upstream doesn't by itself count as drift.

`checks/vm.nix`'s VM test enforces the invariant: it fetches
`/openapi.json` from the running backend, computes the set of anonymous
operations (HTTP GET/POST/PUT/PATCH/DELETE operations with no `security`
key — RomM's `protected_route` decorator is what adds that key), and
asserts both directions against `api-auth.nix`:

- every anonymous path in the spec is covered by some pattern in
  `edgeExempt` or `knownAnonymous` (catches new anonymous endpoints);
- every pattern in `edgeExempt` or `knownAnonymous` matches at least one
  anonymous path in the spec (catches stale entries from routes upstream
  removed or renamed).

If the VM test fails with an uncovered path after a version bump: read the
new endpoint's code to confirm it's genuinely meant to be anonymous, then
add it to `edgeExempt` if an internet-facing proxy should let it through
pre-auth, or to `knownAnonymous` if it should stay behind the edge. Changes
to `edgeExempt` flow to consumers automatically the next time they pull
this flake's `lib.apiAuth`. If the test instead fails on a stale pattern,
remove the entry that no longer matches anything.
