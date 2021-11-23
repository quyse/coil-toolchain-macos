{ buildGoModule
, fetchgit
}:
buildGoModule {
  name = "plist2json";

  src = ./.;

  vendorSha256 = "0x4pihhsvvzglil4nk85sddllw9djvjq5wci01wrsgzv124kp9y9";

  runVend = true;
}
