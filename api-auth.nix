{
  edgeExempt = [
    "/api/heartbeat"
    "/api/token"
    "/api/client-tokens/exchange"
    "/api/client-tokens/pair/*"
    "/api/auth/device/init"
    "/api/auth/device/token"
  ];
  knownAnonymous = [
    "/api/login"
    "/api/logout"
    "/api/login/openid"
    "/api/oauth/openid"
    "/api/forgot-password"
    "/api/reset-password"
    "/api/users/register"
    "/api/heartbeat/metadata/{source}"
    "/api/config"
    "/api/stats"
  ];
}
