{ pkgs
, toolchain
}:
import ./default.nix {
  inherit pkgs toolchain;
}
