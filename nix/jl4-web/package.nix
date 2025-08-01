{
  socket-url ? "localhost:5007",
  session-url ? "localhost:5008",
  secure ? false,
  buildNpmPackage,
  importNpmLock,
  pkg-config,
  libsecret,
  lib,
  ...
}:
buildNpmPackage rec {
  pname = "jl4-web";
  version = "0-latest";
  src = lib.sources.sourceByRegex ../../. [
    "^ts-apps.*"
    "^ts-shared.*"
    "^package-lock.json$"
    "^package.json$"
  ];
  npmDeps = importNpmLock { npmRoot = src; };
  npmWorkspace = src;
  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ libsecret.dev ];
  buildPhase = ''
    runHook preBuild
    set -x
    export VITE_SOCKET_URL=${if secure then "wss" else "ws"}://${socket-url};
    export VITE_SESSION_URL=${if secure then "https" else "http"}://${session-url};

    pushd ./ts-shared

    pushd ./type-utils
    npm run build
    popd

    pushd ./viz-expr
    npm run build
    popd

    pushd ./jl4-client-rpc
    npm run build
    popd

    pushd ./layout-ir
    npm run build
    popd

    pushd ./l4-ladder-visualizer
    npm run build
    popd

    popd

    pushd ./ts-apps

    pushd ./webview
    npm run build
    popd

    # HACK: we need to build workspace dependencies by hand because npm
    # isn't clever enough to figure out workspace dependencies

    pushd ./jl4-web
    npm run build
    set +x
    runHook postBuild
  '';
  installPhase = ''
    mv build $out
  '';
  npmConfigHook = importNpmLock.npmConfigHook;
}
