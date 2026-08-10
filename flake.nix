{
  description = "Rust development environment for true-strike";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = {nixpkgs, ...}: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
  in {
    devShells.${system}.default = pkgs.mkShell {
      packages = with pkgs; [
        cargo
        rustc
        rustfmt
        clippy
        rust-analyzer

        cmake
        pkg-config

        llvmPackages.clang
        llvmPackages.libclang.lib

        opencv4WithoutCuda
        sqlite

        zsh
      ];

      LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";

      LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [
        pkgs.opencv4WithoutCuda
        pkgs.sqlite
        pkgs.stdenv.cc.cc
        pkgs.llvmPackages.libclang.lib
      ];

      shellHook = ''
        export CLANG_PATH=${pkgs.llvmPackages.clang}/bin/clang

        if [[ $- == *i* ]]; then
          exec zsh
        fi
      '';
    };
  };
}
