{ pkgs
, toolchain
}:
let
  root = import ./. {
    inherit pkgs toolchain;
  };
in {
  inherit root;
  touch = {
    inherit (root) catalogPlist;
    inherit (root.packages) run vm;
  };
}
