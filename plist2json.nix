{ fixeds
, buildGoModule
, fetchgit
}:
buildGoModule {
  name = "plist2json";

  src = fetchgit {
    inherit (fixeds.fetchgit."https://github.com/rebeccajae/plist2json.git#default") url rev sha256;
  };

  vendorSha256 = "0x4pihhsvvzglil4nk85sddllw9djvjq5wci01wrsgzv124kp9y9";

  runVend = true;
}
