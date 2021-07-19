{ pkgs
, toolchain
}:
let
  fixeds = builtins.fromJSON (builtins.readFile ./fixeds.json);
in rec {
  catalogVersions = "11-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard";

  catalogPlist = fetchPlist "https://swscan.apple.com/content/catalogs/others/index-${catalogVersions}.merged-1.sucatalog";
  catalog = builtins.fromJSON (builtins.readFile catalogPlist);

  allInstallers = pkgs.lib.pipe catalog.Products [
    # filter only installers
    (pkgs.lib.filterAttrs (key: product:
      ((product.ExtendedMetaInfo or {}).InstallAssistantPackageIdentifiers or {}) ? OSInstall
    ))
    # process
    (pkgs.lib.mapAttrsToList (key: product: let
      metadata = builtins.fromJSON (builtins.readFile (fetchPlist product.ServerMetadataURL));
      localization = metadata.localization;
      desc = localization.English or localization.en;
    in {
      inherit key;
      version = metadata.CFBundleShortVersionString;
      inherit (desc) title;
      date = product.PostDate;
      metadata = product.ServerMetadataURL;
    }))
  ];

  installersByVersion = pkgs.lib.pipe allInstallers [
    # group by version
    (pkgs.lib.groupBy (p: p.version))
    # sort each by date, pick last
    (pkgs.lib.mapAttrs (v: ps: pkgs.lib.pipe ps [
      (pkgs.lib.sort (a: b: a.date < b.date))
      pkgs.lib.last
      (p: catalog.Products."${p.key}")
    ]))
  ];

  macosPackages = { version }: let
    installer = installersByVersion."${version}";
    findSinglePackage = name: with pkgs.lib;
      (findSingle (p: last (splitString "/" p.URL) == name) null null installer.Packages).URL;
    baseSystemImage = pkgs.fetchurl {
      inherit (fixeds.fetchurl."${findSinglePackage "BaseSystem.dmg"}") url sha256 name;
    };

    iso = pkgs.runCommand "fullInstaller.iso" {} ''
      mkdir -p iso/installer.pkg
      # collect packages
      ${pkgs.lib.pipe (installer.Packages ++ [{
        URL = installer.Distributions.English;
      }]) [
        (map (pkg:
          pkgs.lib.optional (pkg ? URL) pkg.URL ++
          pkgs.lib.optional (pkg ? MetadataURL) pkg.MetadataURL ++
          pkgs.lib.optional (pkg ? IntegrityDataURL) pkg.IntegrityDataURL
        ))
        pkgs.lib.concatLists
        (map (url: let
          fixed = fixeds.fetchurl."${url}";
        in ''
          ln -s ${pkgs.fetchurl {
            inherit (fixed) url sha256 name;
          }} iso/installer.pkg/${pkgs.lib.escapeShellArg fixed.name}
        ''))
        pkgs.lib.concatStrings
      ]}
      # make ISO
      ${pkgs.cdrtools}/bin/mkisofs -quiet -iso-level 3 -udf -follow-links -o $out iso
    '';

    vm = pkgs.runCommand "macos-vm" {} ''
      ${qemu}/bin/qemu-img create -f qcow2 hdd.img 256G
      ${qemu}/bin/qemu-img create -f qcow2 installhdd.img 16G
      ${run}
      timeout 1h tail --pid=$(cat vm.pid) -f /dev/null
      echo test_done > $out
    '';

    run = pkgs.writeScript "run.sh" ''
      mkdir -p floppy
      cp ${initScript} floppy/init.sh
      ${qemu}/bin/qemu-system-x86_64 \
        -name macos \
        -enable-kvm \
        -pidfile vm.pid \
        -qmp unix:vm.socket,server,nowait \
        -smp 4,cores=2,threads=2,sockets=1 \
        -m 8G \
        -cpu Penryn,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,+pcid,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check \
        -machine q35 \
        -device isa-applesmc,osk="ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc" \
        -smbios type=2 \
        -device VGA,vgamem_mb=128 \
        -usb -device usb-kbd -device usb-mouse \
        -device usb-ehci,id=ehci \
        -device ich9-ahci,id=sata \
        -drive if=pflash,format=raw,readonly,file=${osxkvm}/OVMF_CODE.fd \
        -drive if=pflash,format=raw,snapshot=on,file=${osxkvm}/OVMF_VARS-1024x768.fd \
        -drive id=OpenCoreBoot,if=none,snapshot=on,format=qcow2,file=${osxkvm}/OpenCore-Catalina/OpenCore-nopicker.qcow2 \
        -device ide-hd,bus=sata.0,drive=OpenCoreBoot \
        -drive id=MacHDD,if=none,file=hdd.img,format=qcow2,cache=unsafe,discard=unmap,detect-zeroes=unmap \
        -device ide-hd,bus=sata.1,drive=MacHDD \
        -drive id=InstallHDD,if=none,file=installhdd.img,format=qcow2,cache=unsafe,discard=unmap,detect-zeroes=unmap \
        -device ide-hd,bus=sata.2,drive=InstallHDD \
        -drive id=InstallMediaBase,if=none,format=dmg,snapshot=on,file=${baseSystemImage} \
        -device ide-hd,bus=sata.3,drive=InstallMediaBase \
        -drive id=ScriptMedia,if=none,file=fat:rw:$PWD/floppy,format=vvfat,cache=unsafe \
        -device ide-hd,bus=sata.5,drive=ScriptMedia \
        -cdrom ${iso} \
        -netdev user,id=net0,restrict=on,hostfwd=tcp:127.0.0.1:20022-:22,hostfwd=tcp:127.0.0.1:5903-:5900 \
        -device vmxnet3,netdev=net0,id=net0 \
        -vnc 127.0.0.1:4 -daemonize

      PATH=$PATH:${pkgs.tesseract4}/bin SOCKET_PATH=vm.socket ${pkgs.nodejs}/bin/node ${./init.js}
    '';

    initScript = pkgs.writeScript "initScript.sh" ''
      # format drives
      # figure out which drive is bigger first
      # macos assignes our drives randomly to disk0 and disk1
      getDiskSize () {
        diskutil info -plist $1 > /tmp/sizeinfo
        /usr/libexec/PlistBuddy -c 'Print :Size' /tmp/sizeinfo
      }
      [ $(getDiskSize /dev/disk0) -gt $(getDiskSize /dev/disk1) ]
      A=$?
      B=$((1 - $A))
      diskutil eraseDisk APFSX MacHDD GPT /dev/disk$A
      diskutil eraseDisk APFSX InstallHDD GPT /dev/disk$B
      # work around bug in installer postinstall scripts
      ln -s /Volumes/InstallHDD/Applications /Volumes/InstallHDDApplications
      # unpack installer
      installer -pkg /Volumes/CDROM/installer.pkg/*.dist -target /Volumes/InstallHDD
      # run installer
      /Volumes/InstallHDD/Applications/Install\ macOS\ *.app/Contents/Resources/startosinstall \
        --agreetolicense --nointeraction --volume /Volumes/MacHDD
    '';

  in {
    inherit run vm;
  };

  fetchPlist = url: let
    fixed = fixeds.fetchurl."${url}"; in
  pkgs.runCommand "${fixed.name}.json" {} ''
    ${plist2json}/bin/plist2json < ${pkgs.fetchurl {
      inherit (fixed) url sha256 name;
    }} > $out
  '';

  osxkvm = pkgs.fetchgit {
    inherit (fixeds.fetchgit."https://github.com/kholia/OSX-KVM.git") url rev sha256;
    fetchSubmodules = false;
  };

  plist2json = pkgs.callPackage ./plist2json.nix {
    inherit fixeds;
  };

  qemu = pkgs.qemu_kvm;
  libguestfs = pkgs.libguestfs-with-appliance.override {
    inherit qemu; # no need to use full qemu
  };

  packages = macosPackages { version = "10.15.7"; };

  touch = {
    inherit catalogPlist;
    inherit (packages) run vm;
  };
}
