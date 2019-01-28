# From GitHub: mozilla/nixpkgs-mozilla/default.nix.

self: super:

with super.lib;

let

  localLib = import ./lib.nix;
  inherit (locallib) nixpkgs-quixoftic nixpkgs-lib-quixoftic;

in
(foldl' (flip extends) (_: super) [
  (import nixpkgs-quixoftic)
  (import nixpkgs-lib-quixoftic)

  (import ./overlays/lib.nix)
]) self
