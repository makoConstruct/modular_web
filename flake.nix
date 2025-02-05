{
  description = "the flutter devshell definition for nixos developers";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      # not doing android builds for now, mobile is no fun
      # let
      #   pkgs = import nixpkgs {
      #     inherit system;
      #     config.allowUnfree = true;
      #     config.android_sdk.accept_license = true;
      #   };
      # in {
      #   devShells.default =
      #     let android = pkgs.callPackage ./nix/android.nix { };
      #     in pkgs.mkShell {
      #       buildInputs = with pkgs; [
      #         # from pkgs
      #         flutter
      #         # changed to 17
      #         jdk17
      #         #from ./nix/*
      #         android.platform-tools
      #       ];

      #       ANDROID_HOME = "${android.androidsdk}/libexec/android-sdk";
      #       JAVA_HOME = pkgs.jdk17;
      #       ANDROID_AVD_HOME = (toString ./.) + "/.android/avd";
      #     };
      # });
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
      in {
        devShells.default = 
          pkgs.mkShell {
            buildInputs = (with pkgs; [flutter327 pkg-config gtk3 gtk3.dev ninja clang glibc]);
          };
      }
    );
}