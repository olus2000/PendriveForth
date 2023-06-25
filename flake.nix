{

description = "A bootable 32-bit Forth system for x86 with(out, yet) a visual block editor";

inputs.nixpkgs = {
  type = "github";
  owner = "NixOS";
  repo = "nixpkgs";
  ref = "nixpkgs-unstable";
};

outputs = { self, nixpkgs }:
let
  pkgs = nixpkgs.legacyPackages."x86_64-linux";
in {
  packages.x86_64-linux.default = pkgs.stdenv.mkDerivation {
    name = "PendriveForth";
    meta = {
      license = pkgs.lib.licenses.gpl3Only;
      description = "A bootable 32-bit Forth system for x86 with(out, yet) a visual block editor";
    };
    src = self;
    buildInputs = [ pkgs.nasm ];

    installPhase = "mkdir $out; cp ./pdf.img $out/";
  };
};

}
