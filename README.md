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
