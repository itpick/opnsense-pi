{
  description = "OPNsense images and VM tests for Raspberry Pi 4/5";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});
    in {
      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [ curl gnumake mtools python3 qemu socat unzip util-linux xz gh shellcheck ];
        };
      });
    };
}
