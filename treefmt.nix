_: {
  projectRootFile = "flake.nix";

  settings.excludes = [ "workspace/*" "LICENSE" ];

  programs = {
    nixpkgs-fmt.enable = true;
    statix.enable = true;
    deadnix.enable = true;
    prettier.enable = true;
    keep-sorted.enable = true;
    zizmor.enable = true;
  };
}
