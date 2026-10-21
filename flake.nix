{
  description = "nix-platform: nix-darwin + home-manager for MacBook-Pro-2, shared overlays later";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nix-darwin.url = "github:nix-darwin/nix-darwin/master";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, nix-darwin, home-manager, ... }: {
    darwinConfigurations."MacBook-Pro-2" = nix-darwin.lib.darwinSystem {
      modules = [
        ./modules/darwin.nix
        { system.configurationRevision = self.rev or self.dirtyRev or null; }
        home-manager.darwinModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          # Existing dotfiles are moved aside, never overwritten.
          home-manager.backupFileExtension = "before-hm";
          home-manager.users.tothemoon = import ./modules/home.nix;
        }
      ];
    };
  };
}
