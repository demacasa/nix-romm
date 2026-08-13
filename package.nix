{ pkgs, pyproject-nix, uv2nix, pyproject-build-systems }:

let
  inherit (pkgs) lib;
  version = "5.1.0";
  srcHash = "sha256-oFJ0R4m3bH2qQ18uTDm749la4oBMBj17Y5lF/eE/6tU=";
  frontendNpmDepsHash = "sha256-rNi0x8vbPkLEiDlf94SPTg4aKguSzVHR5zBouLJulKo=";
  romPatcherNpmDepsHash = "sha256-kle9Sclt1ctyizBVMf83S+r00TvZmUw67i+t1GijNGI=";

  python = pkgs.python313;
  nodejs = pkgs.nodejs_24;

  src = pkgs.fetchFromGitHub {
    owner = "rommapp";
    repo = "romm";
    rev = version;
    hash = srcHash;
  };

  # --- Backend: build the dependency closure from uv.lock via uv2nix ---
  workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./workspace; };
  overlay = workspace.mkPyprojectOverlay { sourcePreference = "wheel"; };

  # sdists that build but forget to declare setuptools as a build dependency.
  needSetuptools = [ "crontab" "pyyaml" "rq-scheduler" ];

  pyprojectOverrides = final: prev:
    (lib.genAttrs needSetuptools (name:
      prev.${name}.overrideAttrs (old: {
        nativeBuildInputs = (old.nativeBuildInputs or [ ])
        ++ final.resolveBuildSystem { setuptools = [ ]; };
      })))
    # Native-library fixups for packages with no usable manylinux wheel.
    // {
      psycopg-c = prev.psycopg-c.overrideAttrs (old: {
        nativeBuildInputs = (old.nativeBuildInputs or [ ])
        ++ [ pkgs.libpq.pg_config ] ++ final.resolveBuildSystem { setuptools = [ ]; };
        buildInputs = (old.buildInputs or [ ]) ++ [ pkgs.libpq ];
      });
      mariadb = prev.mariadb.overrideAttrs (old: {
        nativeBuildInputs = (old.nativeBuildInputs or [ ])
        ++ [ pkgs.mariadb-connector-c ] ++ final.resolveBuildSystem { setuptools = [ ]; };
        buildInputs = (old.buildInputs or [ ]) ++ [ pkgs.mariadb-connector-c ];
      });
      # Wheel vendors optional auth plugins (kerberos/sasl/fido); satisfy the common
      # libs and ignore the exotic ones — RomM does not use these plugins.
      # fastapi and fastapi-cli both ship bin/fastapi; runtime uses gunicorn, drop the dupe.
      fastapi-cli = prev.fastapi-cli.overrideAttrs (old: {
        postInstall = (old.postInstall or "") + ''
          rm -f "$out/bin/fastapi"
        '';
      });
      mysql-connector-python = prev.mysql-connector-python.overrideAttrs (old: {
        buildInputs = (old.buildInputs or [ ])
        ++ [ pkgs.libxcrypt-legacy pkgs.keyutils pkgs.systemdLibs pkgs.libfido2 ];
        autoPatchelfIgnoreMissingDeps = true;
      });
    };

  pythonSet =
    (pkgs.callPackage pyproject-nix.build.packages { inherit python; }).overrideScope
      (lib.composeManyExtensions [
        pyproject-build-systems.overlays.default
        overlay
        pyprojectOverrides
      ]);

  venv = pythonSet.mkVirtualEnv "romm-env" workspace.deps.default;

  # libmagic is dlopen'd at runtime by python-magic; node is shelled out to by
  # the ROM patcher (7zz/bsdtar are patched into archives.py as store paths).
  runtimeLibs = lib.makeLibraryPath [ pkgs.file ];
  runtimeBins = lib.makeBinPath [ nodejs ];

  romPatcherJs = pkgs.buildNpmPackage {
    pname = "romm-rom-patcher";
    inherit version nodejs;
    src = "${src}/backend/utils/rom_patcher";
    npmDepsHash = romPatcherNpmDepsHash;
    dontNpmBuild = true;
    makeCacheWritable = true;
    npmFlags = [ "--ignore-scripts" ];
    installPhase = ''
      runHook preInstall
      cp -r node_modules/rom-patcher/rom-patcher-js $out
      runHook postInstall
    '';
  };

  # --- Frontend: Vue 3 + Vite SPA, served as static files by nginx ---
  frontend = pkgs.buildNpmPackage {
    pname = "romm-frontend";
    inherit version nodejs;
    src = "${src}/frontend";
    npmDepsHash = frontendNpmDepsHash;
    makeCacheWritable = true;
    npmFlags = [ "--ignore-scripts" ];
    installPhase = ''
      runHook preInstall
      cp -r dist $out
      # vite's dist/ omits RomM's raw static tree (logo, platform icons, backgrounds);
      # upstream serves these from the same /assets root (Dockerfile: COPY ./frontend/assets).
      cp -r assets/. $out/assets/
      runHook postInstall
    '';
  };

  backend = pkgs.stdenvNoCC.mkDerivation {
    pname = "romm";
    inherit version src;
    nativeBuildInputs = [ pkgs.makeWrapper ];
    dontConfigure = true;
    dontBuild = true;
    installPhase = ''
      runHook preInstall

      mkdir -p $out/share/romm
      cp -r backend $out/share/romm/backend
      substituteInPlace $out/share/romm/backend/__version__.py \
        --replace-fail '<version>' '${version}'
      substituteInPlace $out/share/romm/backend/utils/archives.py \
        --replace-fail '/usr/bin/7zz' '${pkgs._7zz}/bin/7zz' \
        --replace-fail '/usr/bin/bsdtar' '${pkgs.libarchive}/bin/bsdtar'
      ln -s ${romPatcherJs} $out/share/romm/backend/utils/rom_patcher/rom-patcher-js
      ln -s ${frontend} $out/share/romm/frontend

      # Migrations: alembic upgrade head, run from the backend dir (DB connect happens here).
      makeWrapper ${venv}/bin/alembic $out/bin/romm-migrate \
        --add-flags "upgrade head" \
        --chdir $out/share/romm/backend \
        --set PYTHONPATH $out/share/romm/backend \
        --prefix LD_LIBRARY_PATH : "${runtimeLibs}" \
        --prefix PATH : "${runtimeBins}"

      # One-shot startup tasks: load metadata fixtures into the cache and register
      # scheduled jobs. Production runs this after migrations, before serving.
      makeWrapper ${venv}/bin/python $out/bin/romm-startup \
        --add-flags "startup.py" \
        --chdir $out/share/romm/backend \
        --set PYTHONPATH $out/share/romm/backend \
        --prefix LD_LIBRARY_PATH : "${runtimeLibs}" \
        --prefix PATH : "${runtimeBins}"

      # Web server: gunicorn + uvicorn worker. Bind/workers come from env via GUNICORN_CMD_ARGS.
      makeWrapper ${venv}/bin/gunicorn $out/bin/romm \
        --add-flags "main:app" \
        --chdir $out/share/romm/backend \
        --set PYTHONPATH $out/share/romm/backend \
        --set-default ROMM_PORT 8080 \
        --run 'export GUNICORN_CMD_ARGS="--bind=0.0.0.0:''${ROMM_PORT} --worker-class uvicorn_worker.UvicornWorker --workers ''${WEB_CONCURRENCY:-2} --forwarded-allow-ips=* ''${GUNICORN_CMD_ARGS:-}"' \
        --prefix LD_LIBRARY_PATH : "${runtimeLibs}" \
        --prefix PATH : "${runtimeBins}"

      # Background job worker + scheduler (RQ / Redis).
      makeWrapper ${venv}/bin/rq $out/bin/romm-worker \
        --add-flags "worker --worker-class handler.rq_worker.RomMWorker --path $out/share/romm/backend high default low" \
        --chdir $out/share/romm/backend \
        --set PYTHONPATH $out/share/romm/backend \
        --prefix LD_LIBRARY_PATH : "${runtimeLibs}" \
        --prefix PATH : "${runtimeBins}"

      makeWrapper ${venv}/bin/rqscheduler $out/bin/romm-scheduler \
        --add-flags "--path $out/share/romm/backend" \
        --chdir $out/share/romm/backend \
        --set PYTHONPATH $out/share/romm/backend \
        --prefix LD_LIBRARY_PATH : "${runtimeLibs}" \
        --prefix PATH : "${runtimeBins}"

      # inotify library watcher (optional). Usage: romm-watcher [LIBRARY_DIR]
      # watchfiles re-runs watcher.py whenever the watched directory changes.
      cat > $out/bin/romm-watcher <<EOF
      #!${pkgs.runtimeShell}
      export PYTHONPATH="$out/share/romm/backend"
      export LD_LIBRARY_PATH="${runtimeLibs}\''${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
      export PATH="${runtimeBins}:\$PATH"
      cd "$out/share/romm/backend"
      exec ${venv}/bin/watchfiles --target-type command \
        "${venv}/bin/python watcher.py" "\''${1:-\''${ROMM_BASE_PATH:-/var/lib/romm}/library}"
      EOF
      chmod +x $out/bin/romm-watcher

      cat > $out/bin/romm-sync-watcher <<EOF
      #!${pkgs.runtimeShell}
      export PYTHONPATH="$out/share/romm/backend"
      export LD_LIBRARY_PATH="${runtimeLibs}\''${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
      export PATH="${runtimeBins}:\$PATH"
      cd "$out/share/romm/backend"
      exec ${venv}/bin/watchfiles --target-type command \
        "${venv}/bin/python sync_watcher.py" "\''${1:-\''${ROMM_BASE_PATH:-/var/lib/romm}/sync}"
      EOF
      chmod +x $out/bin/romm-sync-watcher

      runHook postInstall
    '';

    passthru = { inherit frontend venv; };

    meta = {
      description = "Self-hosted ROM manager and player";
      homepage = "https://romm.app/";
      license = lib.licenses.agpl3Only;
      mainProgram = "romm";
      platforms = lib.platforms.linux;
    };
  };
in
{ inherit backend frontend venv; }
