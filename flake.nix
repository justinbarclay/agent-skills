{
  description = "Declarative agent skills management for Home Manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      scriptsFor = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          update-skills = pkgs.writeScriptBin "update-skills" (
            builtins.replaceStrings
              [ "#!/usr/bin/env nu" ]
              [ "#!${pkgs.nushell}/bin/nu" ]
              (builtins.readFile ./update-skills.nu)
          );

          # Runs the generate-inventory block in INVENTORY.org and saves the
          # buffer. The block itself is the generator; this only executes it.
          update-inventory = pkgs.writeShellApplication {
            name = "update-inventory";
            runtimeInputs = [ pkgs.emacs-nox ];
            text = ''
              emacs -Q --batch -l org \
                --eval '(setq org-confirm-babel-evaluate nil)' \
                --visit="''${1:-INVENTORY.org}" \
                --eval '(progn (org-babel-execute-buffer) (save-buffer))'
            '';
          };
        };
    in
    {
      homeManagerModules.default = import ./default.nix;
      homeManagerModules.agentic-skills = self.homeManagerModules.default;

      packages = forAllSystems scriptsFor;

      apps = forAllSystems (system:
        nixpkgs.lib.mapAttrs
          (name: pkg: {
            type = "app";
            program = "${pkg}/bin/${name}";
          })
          (scriptsFor system));

      devShells = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = [ pkgs.nushell ] ++ builtins.attrValues (scriptsFor system);
          };
        });
    };
}
