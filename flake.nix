{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        packer = pkgs.callPackage (
          {
            lib,
            stdenvNoCC,
            zig,
            callPackage,
          }:
          stdenvNoCC.mkDerivation {
            pname = "packer";
            version = "0.1-git";
            src = ./.;
            nativeBuildInputs = [ zig ];
            zigBuildFlags = [
              "--system"
              (callPackage ./build.zig.zon.nix { })
            ];
          }
        ) { };
      in
      {
        devShells.default =
          with pkgs;
          stdenv.mkDerivation {
            name = "dev-shell";
            version = "1.0.0";
            buildInputs = [
              zig
              zls
            ]
            ++ (with llvmPackages_20; [
              bintools
              clang-unwrapped
            ]);
          };
        packages.default = packer;
        packages.packer = packer;
      }
    );
}
