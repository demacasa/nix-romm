{ config
, lib
, pkgs
, ...
}:

let
  cfg = config.services.romm;
  db = cfg.database;
in
{
  options.services.romm = {
    enable = lib.mkEnableOption "RomM self-hosted ROM manager";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.romm;
      defaultText = lib.literalExpression "pkgs.romm";
      description = "The RomM package to run (provides romm, romm-migrate, romm-startup, romm-worker, romm-scheduler, romm-watcher, romm-sync-watcher).";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "TCP port the RomM API/gunicorn server listens on.";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/romm";
      description = ''
        Base path for the ROM library and runtime data. RomM uses
        <literal>$dataDir/{library,resources,assets,config}</literal>.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "romm";
      description = "User account under which RomM runs.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "romm";
      description = "Group under which RomM runs.";
    };

    database = {
      driver = lib.mkOption {
        # These are RomM's own ROMM_DB_DRIVER values; note Postgres is "postgresql".
        type = lib.types.enum [
          "mariadb"
          "postgresql"
          "mysql"
        ];
        default = "mariadb";
        description = "SQL backend RomM connects to. Maps to ROMM_DB_DRIVER.";
      };
      host = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "Database host.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = if db.driver == "postgresql" then 5432 else 3306;
        defaultText = lib.literalExpression ''if driver == "postgresql" then 5432 else 3306'';
        description = "Database port.";
      };
      name = lib.mkOption {
        type = lib.types.str;
        default = "romm";
        description = "Database name.";
      };
      user = lib.mkOption {
        type = lib.types.str;
        default = "romm";
        description = "Database user.";
      };
      createLocally = lib.mkEnableOption "provisioning a local MariaDB database + user for RomM (driver must be \"mariadb\")";
    };

    apiKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to a systemd EnvironmentFile holding secrets, not wired to any DB
        service automatically. Should define at least <literal>ROMM_AUTH_SECRET_KEY</literal>
        and <literal>DB_PASSWD</literal>, plus any scraper keys
        (<literal>IGDB_CLIENT_ID</literal>, <literal>MOBYGAMES_API_KEY</literal>, ...).
      '';
    };

    nginx = {
      enable = lib.mkEnableOption "the nginx frontend/proxy vhost mirroring upstream RomM's production nginx layout";

      port = lib.mkOption {
        type = lib.types.port;
        default = 80;
        description = "TCP port the nginx vhost listens on.";
      };

      virtualHostName = lib.mkOption {
        type = lib.types.str;
        default = "romm";
        description = "Attribute name of the generated services.nginx.virtualHosts entry.";
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      users.users.${cfg.user} = lib.mkIf (cfg.user == "romm") {
        isSystemUser = true;
        inherit (cfg) group;
        home = cfg.dataDir;
      };
      users.groups.${cfg.group} = lib.mkIf (cfg.group == "romm") { };

      # RomM requires Redis for sessions and the RQ job queue. This is the cache/queue,
      # not the SQL database — the SQL server is intentionally left for the user to enable.
      # The default (unnamed) Redis instance: standard redis.service on 127.0.0.1:6379.
      services.redis.servers."" = {
        enable = true;
        port = lib.mkDefault 6379;
        bind = "127.0.0.1";
      };

      systemd.services.romm =
        let
          env = {
            ROMM_BASE_PATH = cfg.dataDir;
            ROMM_PORT = toString cfg.port;
            ROMM_DB_DRIVER = db.driver;
            DB_HOST = db.host;
            DB_PORT = toString db.port;
            DB_NAME = db.name;
            DB_USER = db.user;
            REDIS_HOST = "127.0.0.1";
            REDIS_PORT = toString config.services.redis.servers."".port;
          };
          common = {
            User = cfg.user;
            Group = cfg.group;
            StateDirectory = "romm";
            WorkingDirectory = cfg.dataDir;
            EnvironmentFile = lib.mkIf (cfg.apiKeyFile != null) [ cfg.apiKeyFile ];
            # Hardening
            NoNewPrivileges = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            ReadWritePaths = [ cfg.dataDir ];
            CapabilityBoundingSet = "";
            SystemCallFilter = [ "@system-service" ];
            SystemCallArchitectures = "native";
            RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
            RestrictNamespaces = true;
            RestrictRealtime = true;
            RestrictSUIDSGID = true;
            LockPersonality = true;
            ProtectClock = true;
            ProtectHostname = true;
            ProtectKernelLogs = true;
            ProtectKernelModules = true;
            ProtectKernelTunables = true;
            ProtectControlGroups = true;
            ProtectProc = "invisible";
            ProcSubset = "pid";
          };
        in
        {
          description = "RomM ROM manager";
          wantedBy = [ "multi-user.target" ];
          after = [
            "network.target"
            "redis.service"
            "postgresql.service"
            "mysql.service"
          ];
          wants = [ "redis.service" ];
          environment = env;
          serviceConfig = common // {
            # Apply migrations, then load cache fixtures + register scheduled jobs.
            ExecStartPre = [
              "${cfg.package}/bin/romm-migrate"
              "${cfg.package}/bin/romm-startup"
            ];
            ExecStart = "${cfg.package}/bin/romm";
            Restart = "on-failure";
          };
        };

      # Background job worker + scheduler (scans, scraping, periodic tasks). Both share
      # the main service's environment but skip its migrate/startup ExecStartPre.
      systemd.services.romm-worker = {
        description = "RomM RQ worker";
        wantedBy = [ "multi-user.target" ];
        after = [ "romm.service" ];
        requires = [ "romm.service" ];
        environment = config.systemd.services.romm.environment;
        serviceConfig = config.systemd.services.romm.serviceConfig // {
          ExecStartPre = lib.mkForce [ ];
          ExecStart = lib.mkForce "${cfg.package}/bin/romm-worker";
        };
      };

      systemd.services.romm-scheduler = {
        description = "RomM RQ scheduler";
        wantedBy = [ "multi-user.target" ];
        after = [ "romm.service" ];
        requires = [ "romm.service" ];
        environment = config.systemd.services.romm.environment;
        serviceConfig = config.systemd.services.romm.serviceConfig // {
          ExecStartPre = lib.mkForce [ ];
          ExecStart = lib.mkForce "${cfg.package}/bin/romm-scheduler";
        };
      };

      # Optional inotify watcher that rescans the library on filesystem changes.
      systemd.services.romm-watcher = {
        description = "RomM library watcher";
        wantedBy = [ "multi-user.target" ];
        after = [ "romm.service" ];
        requires = [ "romm.service" ];
        environment = config.systemd.services.romm.environment;
        serviceConfig = config.systemd.services.romm.serviceConfig // {
          ExecStartPre = lib.mkForce [ ];
          ExecStart = lib.mkForce "${cfg.package}/bin/romm-watcher ${cfg.dataDir}/library";
        };
      };

      systemd.services.romm-sync-watcher = {
        description = "RomM sync folder watcher";
        wantedBy = [ "multi-user.target" ];
        after = [ "romm.service" ];
        requires = [ "romm.service" ];
        environment = config.systemd.services.romm.environment;
        serviceConfig = config.systemd.services.romm.serviceConfig // {
          ExecStartPre = lib.mkForce [ ];
          ExecStart = lib.mkForce "${cfg.package}/bin/romm-sync-watcher ${cfg.dataDir}/sync";
        };
      };

      systemd.tmpfiles.rules = [
        "d ${cfg.dataDir}/sync 0755 ${cfg.user} ${cfg.group} -"
        "d ${cfg.dataDir}/cache 0755 ${cfg.user} ${cfg.group} -"
      ];
    }

    (lib.mkIf db.createLocally {
      assertions = [
        {
          assertion = db.driver == "mariadb";
          message = "services.romm.database.createLocally only supports driver = \"mariadb\".";
        }
        {
          # romm-db-setup reads DB_PASSWD from apiKeyFile; without it the user is
          # created with an empty password (auth disabled).
          assertion = cfg.apiKeyFile != null;
          message = "services.romm.database.createLocally requires services.romm.apiKeyFile to be set (it must define DB_PASSWD for the provisioned MariaDB user).";
        }
      ];

      # Local MariaDB, bound to loopback; nothing off-host needs it.
      services.mysql = {
        enable = true;
        package = pkgs.mariadb;
        settings.mysqld.bind-address = "127.0.0.1";
      };

      # ensureUsers makes unix-socket users, but RomM connects over TCP with a
      # password. So provision the db + password user directly as root (socket
      # auth) each start, reading DB_PASSWD from the EnvironmentFile. Idempotent.
      systemd.services.romm-db-setup = {
        description = "RomM MariaDB database/user provisioning";
        after = [ "mysql.service" ];
        requires = [ "mysql.service" ];
        before = [ "romm.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "root";
          EnvironmentFile = lib.mkIf (cfg.apiKeyFile != null) [ cfg.apiKeyFile ];
        };
        script = ''
          ${config.services.mysql.package}/bin/mysql <<SQL
          CREATE DATABASE IF NOT EXISTS \`${db.name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
          CREATE USER IF NOT EXISTS '${db.user}'@'127.0.0.1' IDENTIFIED BY '$DB_PASSWD';
          ALTER USER '${db.user}'@'127.0.0.1' IDENTIFIED BY '$DB_PASSWD';
          GRANT ALL PRIVILEGES ON \`${db.name}\`.* TO '${db.user}'@'127.0.0.1';
          FLUSH PRIVILEGES;
          SQL
        '';
      };

      systemd.services.romm = {
        after = [ "romm-db-setup.service" ];
        requires = [ "romm-db-setup.service" ];
      };
    })

    (lib.mkIf cfg.nginx.enable (
      let
        backend = "http://127.0.0.1:${toString cfg.port}";
        rommProxyHeaders = ''
          proxy_set_header Host $host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $romm_forwardscheme;
        '';
      in
      {
        services.nginx = {
          enable = true;
          additionalModules = [ pkgs.nginxModules.zip pkgs.nginxModules.njs ];
          clientMaxBodySize = "0";
          appendHttpConfig = ''
            send_timeout 600s;
            client_body_timeout 600s;
          '';
          commonHttpConfig = ''
            js_import rommdecode from ${./romm-decode.js};
            map $http_x_forwarded_proto $romm_forwardscheme { default $scheme; https https; }
            map $args $resources_cache_control {
              default         "public, max-age=3600, must-revalidate";
              "~(^|&)(ts|v)=" "public, max-age=31536000, immutable";
            }
          '';
          virtualHosts.${cfg.nginx.virtualHostName} = {
            listen = [{ addr = "0.0.0.0"; port = cfg.nginx.port; }];
            root = "${cfg.package.passthru.frontend}";
            locations = {
              "/" = {
                tryFiles = "$uri $uri/ /index.html";
                extraConfig = ''
                  add_header Cache-Control "no-cache";
                '';
              };
              "~* \"^/assets/[^/]+-[A-Za-z0-9_-]{8,}\\.(js|mjs|css|map|woff2?|ttf|otf|eot|svg|png|jpe?g|gif|webp|avif|ico|json|wasm)$\"" = {
                tryFiles = "$uri =404";
                extraConfig = ''
                  add_header Cache-Control "public, max-age=31536000, immutable";
                '';
              };
              # 404 on asset miss — do NOT fall back to index.html (broken image vs. HTML).
              "/assets" = {
                tryFiles = "$uri $uri/ =404";
                extraConfig = ''
                  add_header Cache-Control "public, max-age=3600, must-revalidate";
                '';
              };
              "/assets/romm/resources/".extraConfig = ''
                alias ${cfg.dataDir}/resources/;
                add_header Cache-Control $resources_cache_control;
              '';
              "/assets/romm/assets/".extraConfig = "alias ${cfg.dataDir}/assets/;";
              "/openapi.json" = {
                proxyPass = backend;
                extraConfig = rommProxyHeaders;
              };
              "/api" = {
                proxyPass = backend;
                extraConfig = rommProxyHeaders + ''
                  proxy_request_buffering off;
                  proxy_buffering off;
                  proxy_read_timeout 300s;
                '';
              };
              "~ ^/(ws|netplay)" = {
                proxyPass = backend;
                proxyWebsockets = true;
                extraConfig = rommProxyHeaders;
              };
              # Internal: efficient single-file downloads via backend X-Accel-Redirect.
              "/library/" = {
                extraConfig = ''
                  internal;
                  alias ${cfg.dataDir}/library/;
                '';
              };
              "/cache/" = {
                extraConfig = ''
                  internal;
                  alias ${cfg.dataDir}/cache/;
                '';
              };
              # Internal: base64 filename decode for mod_zip multi-file zip manifests.
              "/decode" = {
                extraConfig = ''
                  internal;
                  js_content rommdecode.decodeBase64;
                '';
              };
            };
          };
        };
      }
    ))
  ]);
}
