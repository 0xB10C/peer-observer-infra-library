{
  config,
  stdenv,
  lib,
  ...
}:

let
  CONSTANTS = import ../constants.nix;

  mkHTMLPage = title: body: ''
      <!doctype html>
      <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>${title}</title>
        </head>
        <body>
          <div class="container">
            ${body}
          </div>
        </body>
    </html>
  '';

  # mkOverviewNodeEntry takes name, host, and index
  mkOverviewNodeEntry = name: host: index: ''
    <li>
      <span>
        <a href="/debug-logs/${name}/">node ${name}</a>
      </span>
      ${lib.optionalString host.bitcoind.net.useTor "+debug=tor"}
      ${lib.optionalString host.bitcoind.net.useI2P "+debug=i2p"}
    </li>
  '';

  # mkOverviewNodeList maps over host attrset and passes name, host, index
  mkOverviewNodeList = hosts: ''
    <div class="row">
      ${builtins.concatStringsSep "  " (
        lib.imap1 (i: name: mkOverviewNodeEntry name hosts.${name} i) (builtins.attrNames hosts)
      )}
    </div>
  '';

in
stdenv.mkDerivation rec {
  name = "debug-log-page";

  phases = [ "installPhase" ];

  installPhase = ''
        mkdir -p $out
        cat > $out/index.html << EOF
        ${
          (mkHTMLPage "peer-observer debug-logs" (''
            <h1>peer-observer debug.logs</h1>
            <span>
              Daily copies of compressed node debug.logs are kept. These are provided as is and <b style="color: red;">might contain sensitive information such as honey-pot node IP addresses</b>.
              <br>
              Feel free to use the debug.logs but please make sure to not leak the node IP addresses to the public.  
              <br>
              <br>
              Current debug.logs contain the following categories. Older logs might not have all categories enabled yet.
              <ul>
              ${lib.concatStrings (map (cat: "<li>${cat}</li>") CONSTANTS.DETAILED_DEBUG_LOG_CATEGORIES)}
              </ul>
            </span>
            <h2>debug.logs</h2>
            <p>
              Some node have extra log categories turned on:
              <ul>
                ${(mkOverviewNodeList config.infra.nodes)}
              </ul>
            </p>
          ''))
        }
    EOF
  '';
}
