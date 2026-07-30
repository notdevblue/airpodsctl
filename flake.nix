{
  description = "One-shot AirPods control and status utility for Linux";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        rec {
          airpodsctl = pkgs.stdenv.mkDerivation {
            pname = "airpodsctl";
            version = "0.5.0";
            src = self;

            nativeBuildInputs = [
              pkgs.pkg-config
              pkgs.zig_0_16
            ];
            buildInputs = [
              pkgs.bluez
              pkgs.systemd
            ];

            # Keep Zig's global cache in writable storage inside the Nix build sandbox.
            buildPhase = ''
              runHook preBuild
              ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache" \
                zig build -Doptimize=ReleaseSafe -Dversion=0.5.0
              runHook postBuild
            '';
            doCheck = true;
            checkPhase = ''
              runHook preCheck
              ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache" \
                zig build check -Doptimize=ReleaseSafe -Dversion=0.5.0
              runHook postCheck
            '';
            installPhase = ''
              runHook preInstall
              ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache" \
                zig build install \
                  -Doptimize=ReleaseSafe \
                  -Dversion=0.5.0 \
                  --prefix "$out"
              runHook postInstall
            '';

            meta = {
              description = "Read and control AirPods without a daemon";
              homepage = "https://github.com/hacel/airpodsctl";
              license = pkgs.lib.licenses.mit;
              mainProgram = "airpodsctl";
              platforms = pkgs.lib.platforms.linux;
            };
          };

          default = airpodsctl;
        }
      );

      checks = forAllSystems (system: {
        inherit (self.packages.${system}) airpodsctl;
      });

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.bluez
              pkgs.pkg-config
              pkgs.systemd
              pkgs.zig_0_16
            ];
          };
        }
      );
    };
}
