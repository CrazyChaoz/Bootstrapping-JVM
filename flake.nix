{
  description = "Bootstrapping Kotlin and Gradle from source with Nix";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/02c087f3fe673c9e317f206a627cb6b910336dbe";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      scope = import ./pkgs/top-level/all-packages.nix { inherit pkgs; };
    in
    {
      # Everything, including intermediate stages: `nix build .#kotlin.v1_0_0`
      legacyPackages.${system} = scope;
      packages.${system} = {
        inherit (scope) ant;
        default = scope.ant;
      };
    };
}
