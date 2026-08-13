{ pkgs, module }:

# Boots a single node with the RomM module + createLocally MariaDB + Redis,
# and asserts that:
#  - all units come up and migrations apply
#  - the backend answers on its gunicorn port
#  - nginx serves static assets with correct content-type (catches broken-logo class)
#  - /openapi.json is proxied to the backend (was SPA HTML before nginx fix)
#  - /library/ and /cache/ are gated as internal (proves X-Accel gating, not open to direct fetches)
#  - index.html is served with Cache-Control no-cache (stale index → blank page after upgrades)
#  - the running nginx config forwards all four proxy headers (catches dropped-Host bug)
pkgs.testers.runNixOSTest {
  name = "romm";

  nodes.machine = _: {
    imports = [ module ];

    # Test-only secret file (store-visible is fine in a VM test).
    environment.etc."romm-test.env".text = ''
      ROMM_AUTH_SECRET_KEY=0000000000000000000000000000000000000000000000000000000000000000
      DB_PASSWD=testpass
    '';

    services.romm = {
      enable = true;
      port = 8081;
      database.createLocally = true;
      apiKeyFile = "/etc/romm-test.env";
      nginx = {
        enable = true;
        port = 8083;
      };
    };

    # enableReload places the full flattened config at /etc/nginx/nginx.conf so the
    # grep assertions below can check the deployed file deterministically.
    services.nginx.enableReload = true;

    # Create the library dir so romm-watcher doesn't crash on missing path.
    systemd.tmpfiles.rules = [
      "d /var/lib/romm/library 0755 romm romm -"
    ];

    virtualisation = {
      memorySize = 3072;
      diskSize = 4096;
      cores = 2;
    };
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("mysql.service")
    machine.wait_for_unit("redis.service")
    machine.wait_for_unit("romm-db-setup.service")
    machine.wait_for_unit("romm.service")
    machine.wait_for_unit("romm-worker.service")
    machine.wait_for_unit("romm-scheduler.service")
    machine.wait_for_unit("romm-sync-watcher.service")

    # Backend answers on its gunicorn port (migrations ran in ExecStartPre).
    machine.wait_for_open_port(8081)
    machine.succeed("curl -fsS http://127.0.0.1:8081/api/heartbeat")

    machine.wait_for_open_port(8083)

    # Logo/static asset served with correct content-type (was 404 → broken image).
    machine.succeed("curl -fsS -o /dev/null -w '%{content_type}' http://localhost:8083/assets/isotipo.svg | grep -qi 'image/svg'")

    # OpenAPI JSON proxied to backend (was SPA HTML before nginx fix).
    machine.succeed("curl -fsS http://localhost:8083/openapi.json | grep -q '\"openapi\"'")

    # /library/ and /cache/ are internal — direct requests must NOT serve files (X-Accel gating).
    machine.succeed("test $(curl -s -o /dev/null -w '%{http_code}' http://localhost:8083/library/) -ge 400")
    machine.succeed("test $(curl -s -o /dev/null -w '%{http_code}' http://localhost:8083/cache/) -ge 400")

    machine.succeed("curl -fsS -D- -o /dev/null http://localhost:8083/ | grep -i 'cache-control: no-cache'")
    machine.succeed("curl -fsS -D- -o /dev/null http://localhost:8083/assets/isotipo.svg | grep -i 'cache-control: public, max-age=3600'")

    # Running nginx config must forward all proxy headers (catches dropped-Host class of bug).
    # /etc/nginx/nginx.conf is present because enableReload = true; grep is deterministic
    # against the deployed file without needing nginx -T to find its compiled-in config path.
    machine.succeed("grep -q 'proxy_set_header Host' /etc/nginx/nginx.conf")
    machine.succeed("grep -q 'proxy_set_header X-Forwarded-For' /etc/nginx/nginx.conf")
    machine.succeed("grep -q 'proxy_set_header X-Real-IP' /etc/nginx/nginx.conf")
    machine.succeed("grep -q 'proxy_set_header X-Forwarded-Proto' /etc/nginx/nginx.conf")
  '';
}
