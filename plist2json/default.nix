{ buildGoModule
, fetchgit
}:
buildGoModule {
  name = "plist2json";

  src = ./.;

  vendorSha256 = "sha256-gxgowj3ZhDdjbn0cxfpRfPH+3gc/i+6Qm33zDIqiM1A=";
}
