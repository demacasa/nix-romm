// Decode a Base64 encoded string received as a query parameter named 'value',
// and return the decoded value in the response body. (Vendored from RomM 4.9.2,
// docker/nginx/js/decode.js — used by mod_zip manifests for non-ASCII filenames.)
function decodeBase64(r) {
  var encodedValue = r.args.value;
  if (!encodedValue) {
    r.return(400, "Missing 'value' query parameter");
    return;
  }
  try {
    // Buffer (not atob) so non-ASCII bytes in filenames (e.g. "Pokémon") aren't
    // re-encoded as UTF-8 and CRC-mismatched in the mod_zip manifest.
    r.return(200, Buffer.from(encodedValue, "base64"));
  } catch (e) {
    r.return(400, "Invalid Base64 encoding");
  }
}
export default { decodeBase64 };
