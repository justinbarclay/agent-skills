{
  description = "Declarative agent skills management for Home Manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      homeManagerModules.default = import ./default.nix;
      homeManagerModules.agentic-skills = self.homeManagerModules.default;

      devShells = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          update-skills = pkgs.writeScriptBin "update-skills" (
            builtins.replaceStrings
              [ "#!/usr/bin/env nu" ]
              [ "#!${pkgs.nushell}/bin/nu" ]
              (builtins.readFile ./update-skills.nu)
          );
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.nushell
              update-skills
            ];
          };
        });
    };
}
