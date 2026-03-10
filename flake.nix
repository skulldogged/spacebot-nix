{
  description = "Standalone Nix packaging for Spacebot";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    crane.url = "github:ipetkov/crane";

    spacebot-src = {
      url = "github:spacedriveapp/spacebot";
      flake = false;
    };
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    crane,
    spacebot-src,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = import nixpkgs {
          inherit system;
        };

        craneLib = crane.mkLib pkgs;

        sources = import ./nix/sources.nix {
          inherit (pkgs) lib;

          root = spacebot-src;
        };

        spacebotPackages = import ./nix {
          inherit pkgs craneLib;
          inherit (sources) cargoSrc runtimeAssetsSrc frontendSrc;
        };

        inherit (spacebotPackages) frontend spacebot spacebot-full spacebot-tests;
      in {
        packages = {
          inherit frontend spacebot spacebot-full;
          default = spacebot-full;
        };

        devShells = {
          default = pkgs.mkShell {
            packages = with pkgs; [
              rustc
              cargo
              rustfmt
              rust-analyzer
              clippy
              bun
              nodejs
              protobuf
              cmake
              openssl
              pkg-config
              onnxruntime
              chromium
            ];

            ORT_LIB_LOCATION = "${pkgs.onnxruntime}/lib";
            CHROME_PATH = "${pkgs.chromium}/bin/chromium";
            CHROME_FLAGS = "--no-sandbox --disable-dev-shm-usage --disable-gpu";
          };

          backend = pkgs.mkShell {
            packages = with pkgs; [
              rustc
              cargo
              rustfmt
              rust-analyzer
              clippy
              protobuf
              cmake
              openssl
              pkg-config
              onnxruntime
            ];

            ORT_LIB_LOCATION = "${pkgs.onnxruntime}/lib";
          };
        };

        checks = {
          inherit spacebot spacebot-full spacebot-tests;
        };
      }
    )
    // {
      overlays.default = final: {
        inherit (self.packages.${final.system}) spacebot spacebot-full;
      };

      nixosModules.default = import ./nix/module.nix self;
    };
}
