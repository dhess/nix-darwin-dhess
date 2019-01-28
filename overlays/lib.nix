self: super:

let
  callLibs = file: import file { pkgs = self; lib = self.lib; };

  # New types for nix-darwin modules.
  localTypes = callLibs ./lib/types.nix;
in
{
  lib = (super.lib or {}) // {
    maintainers = super.lib.maintainers // {
      dhess-pers = "Drew Hess <src@drewhess.com>";
    };

    nix-darwin-dhess = {
      # Provide access to the whole package, if needed.
      path = ../.;

      # A list of all the nix-darwin modules exported by this package.
      modulesPath = ../modules/module-list.nix;
    };

    types = (super.lib.types or {}) // localTypes;
  };
}
