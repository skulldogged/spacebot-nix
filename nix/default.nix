{
  pkgs,
  craneLib,
  cargoSrc,
  runtimeAssetsSrc,
  frontendSrc,
}: let
  inherit (pkgs) lib onnxruntime stdenv;

  frontendNodeModulesHash = "sha256-FQ1FtEDT4YToVCA6tTqrYiv/06sa5K4FYTywpjUQDRM=";

  bunInstallOs =
    if stdenv.hostPlatform.isDarwin
    then "darwin"
    else if stdenv.hostPlatform.isLinux
    then "linux"
    else throw "Unsupported host platform for frontend Bun install: ${stdenv.hostPlatform.system}";

  bunInstallCpu =
    if stdenv.hostPlatform.isAarch64
    then "arm64"
    else if stdenv.hostPlatform.isx86_64
    then "x64"
    else throw "Unsupported host CPU for frontend Bun install: ${stdenv.hostPlatform.system}";

  rollupNativePackage =
    if stdenv.hostPlatform.isLinux && stdenv.hostPlatform.isx86_64
    then "@rollup/rollup-linux-x64-gnu"
    else if stdenv.hostPlatform.isLinux && stdenv.hostPlatform.isAarch64
    then "@rollup/rollup-linux-arm64-gnu"
    else if stdenv.hostPlatform.isDarwin && stdenv.hostPlatform.isx86_64
    then "@rollup/rollup-darwin-x64"
    else if stdenv.hostPlatform.isDarwin && stdenv.hostPlatform.isAarch64
    then "@rollup/rollup-darwin-arm64"
    else null;

  esbuildNativePackage =
    if stdenv.hostPlatform.isLinux && stdenv.hostPlatform.isx86_64
    then "@esbuild/linux-x64"
    else if stdenv.hostPlatform.isLinux && stdenv.hostPlatform.isAarch64
    then "@esbuild/linux-arm64"
    else if stdenv.hostPlatform.isDarwin && stdenv.hostPlatform.isx86_64
    then "@esbuild/darwin-x64"
    else if stdenv.hostPlatform.isDarwin && stdenv.hostPlatform.isAarch64
    then "@esbuild/darwin-arm64"
    else null;

  cargoToml = fromTOML (builtins.readFile "${cargoSrc}/Cargo.toml");
  inherit (cargoToml.package) version;

  swaggerUi = pkgs.fetchurl {
    url = "https://github.com/swagger-api/swagger-ui/archive/refs/tags/v5.17.14.zip";
    hash = "sha256-SBJE0IEgl7Efuu73n3HZQrFxYX+cn5UU5jrL4T5xzNw=";
  };

  buildInputs = with pkgs; [
    protobuf
    cmake
    openssl
    pkg-config
    onnxruntime
  ];

  nativeBuildInputs = with pkgs; [
    pkg-config
    protobuf
    cmake
  ] ++ lib.optionals stdenv.isLinux [pkgs.mold];

  frontendNodeModules = stdenv.mkDerivation {
    pname = "spacebot-frontend-node-modules";
    inherit version;
    src = frontendSrc;
    sourceRoot = "source/interface";

    nativeBuildInputs = with pkgs; [
      bun
      nodejs
      writableTmpDirAsHomeHook
    ];

    dontConfigure = true;
    dontFixup = true;

    buildPhase = ''
      runHook preBuild

      export BUN_INSTALL_CACHE_DIR="$(mktemp -d)"
      bun install \
        --frozen-lockfile \
        --ignore-scripts \
        --no-progress \
        --os=${bunInstallOs} \
        --cpu=${bunInstallCpu}

      esbuild_native_package="${if esbuildNativePackage == null then "" else esbuildNativePackage}"
      if [ -n "$esbuild_native_package" ]; then
        esbuild_version="$(node -p "require('./node_modules/esbuild/package.json').version")"
        bun add --dev --no-save --no-progress "$esbuild_native_package@$esbuild_version"
      fi

      rollup_native_package="${if rollupNativePackage == null then "" else rollupNativePackage}"
      if [ -n "$rollup_native_package" ]; then
        rollup_version="$(node -p "require('./node_modules/rollup/package.json').version")"
        bun add --dev --no-save --no-progress "$rollup_native_package@$rollup_version"
      fi

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out
      cp -r node_modules $out/node_modules

      runHook postInstall
    '';

    outputHash = frontendNodeModulesHash;
    outputHashAlgo = "sha256";
    outputHashMode = "recursive";
  };

  frontend = stdenv.mkDerivation {
    pname = "spacebot-frontend";
    inherit version;
    src = frontendSrc;
    sourceRoot = "source/interface";

    nativeBuildInputs = with pkgs; [
      bun
      nodejs
    ];

    dontConfigure = true;

    buildPhase = ''
      runHook preBuild

      cp -r ${frontendNodeModules}/node_modules .
      chmod -R u+w node_modules
      patchShebangs --build node_modules

      bun run build

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out
      cp -r dist/* $out/

      runHook postInstall
    '';
  };

  commonArgs = {
    inherit nativeBuildInputs buildInputs;
    strictDeps = true;
    cargoExtraArgs = "";
  };

  commonArgsWithSrc = commonArgs // {
    src = cargoSrc;
  };

  commonRustBuildEnv = ''
    export ORT_LIB_LOCATION=${onnxruntime}/lib
    export CARGO_PROFILE_RELEASE_LTO=off
    export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=256
    export SWAGGER_UI_DOWNLOAD_URL=file://${swaggerUi}
  '';

  commonRustBuildEnvWithLinker =
    commonRustBuildEnv
    + lib.optionalString stdenv.isLinux ''
      if [ -n "''${RUSTFLAGS:-}" ]; then
        export RUSTFLAGS="$RUSTFLAGS -C link-arg=-fuse-ld=mold"
      else
        export RUSTFLAGS="-C link-arg=-fuse-ld=mold"
      fi
    '';

  commonBuildEnv = ''
    export SPACEBOT_SKIP_FRONTEND_BUILD=1
    mkdir -p interface/dist
    cp -r ${frontend}/* interface/dist/
  '';

  commonBuildEnvWithLinker = commonRustBuildEnvWithLinker + commonBuildEnv;

  dummyRustSource = pkgs.writeText "dummy.rs" ''
    #![allow(dead_code)]
    fn main() {}
  '';

  cargoDummySrc = craneLib.mkDummySrc {
    src = cargoSrc;
    dummyrs = dummyRustSource;
    dummyBuildrs = "build.rs";
    extraDummyScript = ''
      cp ${dummyRustSource} $out/build.rs
      rm -rf $out/vendor
      cp -r ${cargoSrc}/vendor $out/vendor
      chmod -R u+w $out/vendor
    '';
  };

  spacebotCargoArtifacts = craneLib.buildDepsOnly (commonArgs
    // {
      cargoExtraArgs = "--bin spacebot";
      doCheck = false;
      cargoCheckCommand = "true";
      dummySrc = cargoDummySrc;
      preBuild = commonRustBuildEnvWithLinker;
    });

  spacebotTestsCargoArtifacts = craneLib.buildDepsOnly (commonArgs
    // {
      doCheck = false;
      cargoCheckCommand = "true";
      dummySrc = cargoDummySrc;
      preBuild = commonRustBuildEnvWithLinker;
    });

  spacebot = craneLib.buildPackage (commonArgsWithSrc
    // {
      cargoArtifacts = spacebotCargoArtifacts;
      doCheck = false;
      cargoExtraArgs = "--bin spacebot";

      preBuild = commonBuildEnvWithLinker;

      postInstall = ''
        mkdir -p $out/share/spacebot
        cp -r ${runtimeAssetsSrc}/prompts $out/share/spacebot/
        cp -r ${runtimeAssetsSrc}/migrations $out/share/spacebot/
        chmod -R u+w $out/share/spacebot
      '';

      meta = with lib; {
        description = "An AI agent for teams, communities, and multi-user environments";
        homepage = "https://spacebot.sh";
        license = {
          shortName = "FSL-1.1-ALv2";
          fullName = "Functional Source License, Version 1.1, ALv2 Future License";
          url = "https://fsl.software/";
          free = true;
          redistributable = true;
        };
        platforms = platforms.linux ++ platforms.darwin;
        mainProgram = "spacebot";
      };
    });

  spacebot-tests = craneLib.cargoTest (commonArgsWithSrc
    // {
      cargoArtifacts = spacebotTestsCargoArtifacts;

      cargoTestExtraArgs = "-- --skip memory::search::tests --skip memory::store::tests --skip config::tests::test_llm_provider_tables_parse_with_env_and_lowercase_keys";

      preBuild = commonBuildEnvWithLinker;
    });

  spacebot-full = pkgs.symlinkJoin {
    name = "spacebot-full";
    paths = [spacebot];

    buildInputs = [pkgs.makeWrapper];

    postBuild = ''
      wrapProgram $out/bin/spacebot \
        --set CHROME_PATH "${pkgs.chromium}/bin/chromium" \
        --set CHROME_FLAGS "--no-sandbox --disable-dev-shm-usage --disable-gpu" \
        --set ORT_LIB_LOCATION "${onnxruntime}/lib"
    '';

    meta =
      spacebot.meta
      // {
        description = spacebot.meta.description + " (with browser support)";
      };
  };
in {
  inherit frontend spacebot spacebot-full spacebot-tests;
}
