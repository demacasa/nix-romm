{
  description = "Native Nix package and NixOS module for RomM, the self-hosted ROM manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, treefmt-nix, ... }@inputs:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      mkRomm = p: import ./package.nix {
        pkgs = p;
        inherit (inputs) pyproject-nix uv2nix pyproject-build-systems;
      };

      treefmt = treefmt-nix.lib.evalModule pkgs ./treefmt.nix;

      apiAuth = import ./api-auth.nix;
    in
    {
      packages.${system} = rec {
        romm = (mkRomm pkgs).backend;
        default = romm;
      };

      lib.apiAuth = apiAuth;

      overlays.default = final: _prev: {
        romm = (mkRomm final).backend;
      };

      nixosModules.default = { lib, pkgs, ... }: {
        imports = [ ./module.nix ];
        services.romm.package = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.romm;
      };

      checks.${system} = {
        romm = import ./checks/vm.nix {
          inherit pkgs apiAuth;
          module = self.nixosModules.default;
        };
        formatting = treefmt.config.build.check self;
      };

      formatter.${system} = treefmt.config.build.wrapper;

      devShells.${system}.default = pkgs.mkShell {
        packages = [ treefmt.config.build.wrapper ];
      };
    };
}
