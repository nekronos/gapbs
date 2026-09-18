 let
   nixpkgs = fetchTarball "https://github.com/NixOS/nixpkgs/tarball/nixpkgs-unstable";
   pkgs = import nixpkgs { config = {}; overlays = []; };
 in

 pkgs.mkShellNoCC {
   packages = with pkgs; [
     clang_22
     llvmPackages_22.openmp
     wget
     just
   ];

  CXX="clang++";
 }
