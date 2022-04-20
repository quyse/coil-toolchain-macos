{ pkgs ? import <nixpkgs> {}
, lib ? pkgs.lib
, toolchain
, xml ? toolchain.utils.xml
, fixedsFile ? ./fixeds.json
, fixeds ? lib.importJSON fixedsFile
}:

rec {
  catalogVersions = "12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard";

  catalogPlist = fetchPlist "https://swscan.apple.com/content/catalogs/others/index-${catalogVersions}.merged-1.sucatalog";
  catalog = lib.importJSON catalogPlist;

  products = catalog.Products;

  allOSInstallers = lib.pipe products [
    # filter only installers
    (lib.filterAttrs (key: product:
      (product.ExtendedMetaInfo or {}) ? InstallAssistantPackageIdentifiers
    ))
    # process
    (lib.mapAttrsToList (key: product: let
      distributionXml = pkgs.fetchurl {
        inherit (fixeds.fetchurl."${product.Distributions.English}") url sha256 name;
      };
      distributionJson = pkgs.runCommand "${key}.json" {} ''
        ${pkgs.yq}/bin/xq < ${distributionXml} > $out
      '';
      info = lib.pipe distributionJson [
        lib.importJSON
        (xml.getTag "installer-gui-script")
        (root: let
          auxinfo = xml.getTag "auxinfo" root;
          dict = xml.getTag "dict" auxinfo;
          keys = xml.getTags "key" dict;
          values = xml.getTags "string" dict;
          list = lib.zipListsWith lib.nameValuePair keys values;
        in lib.listToAttrs list // {
          title = xml.getTag "title" root;
        })
      ];
    in {
      inherit key distributionJson;
      version = info.VERSION;
      inherit (info) title;
      date = product.PostDate;
    }))
  ];

  osInstallersByVersion = lib.pipe allOSInstallers [
    # group by version
    (lib.groupBy (p: p.version))
    # sort each by date, pick last
    (lib.mapAttrs (v: ps: lib.pipe ps [
      (lib.sort (a: b: a.date < b.date))
      lib.last
      (p: products."${p.key}")
    ]))
  ];

  # symlink installer packages into dir
  installerScript = installer: lib.pipe (installer.Packages ++ [{
    URL = installer.Distributions.English;
  }]) [
    (map (pkg: lib.optional (pkg ? URL) pkg.URL))
    lib.concatLists
    (map (url: let
      fixed = fixeds.fetchurl."${url}" or null;
    in ''
      ln -s ${if fixed == null then builtins.trace url (builtins.fetchurl url) else pkgs.fetchurl {
        inherit (fixed) url sha256 name;
      }} ${lib.escapeShellArg (if fixed == null then "zzz" else fixed.name)}
    ''))
    lib.concatStrings
  ];

  macosPackages = { version, baseSystemVersion }: let
    baseSystem = osInstallersByVersion."${baseSystemVersion}";
    findSinglePackage = name: with lib;
      (findSingle (p: last (splitString "/" p.URL) == name) null null baseSystem.Packages).URL;
    baseSystemImage = pkgs.fetchurl {
      inherit (fixeds.fetchurl."${findSinglePackage "BaseSystem.dmg"}") url sha256 name;
    };

    iso = pkgs.runCommand "fullInstaller.iso" {} ''
      mkdir -p iso/installer.pkg
      pushd iso/installer.pkg
      ${installerScript osInstallersByVersion."${version}"}
      popd
      ${pkgs.cdrtools}/bin/mkisofs -quiet -iso-level 3 -udf -follow-links -o $out iso
    '';

    runInstall = hdd: pkgs.writeScript "runInstall.sh" ''
      set -eu
      mkdir -p floppy/scripts
      cp ${initScript} floppy/init.sh
      cp ${postinstallPackage} floppy/bootstrap.pkg
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
        -drive if=pflash,format=raw,readonly=on,file=${osxkvm}/OVMF_CODE.fd \
        -drive if=pflash,format=raw,snapshot=on,file=${osxkvm}/OVMF_VARS-1024x768.fd \
        -drive id=OpenCoreBoot,if=none,snapshot=on,format=qcow2,file=${osxkvm}/OpenCore/OpenCore.qcow2 \
        -device ide-hd,bus=sata.0,drive=OpenCoreBoot \
        -drive id=MacHDD,if=none,file=${hdd},format=qcow2,cache=unsafe,discard=unmap,detect-zeroes=unmap \
        -device ide-hd,bus=sata.1,drive=MacHDD \
        -drive id=InstallHDD,if=none,file=installhdd.qcow2,format=qcow2,cache=unsafe,discard=unmap,detect-zeroes=unmap \
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
        --agreetolicense --nointeraction --volume /Volumes/MacHDD \
        --installpackage "/Volumes/QEMU VVFAT/bootstrap.pkg"
    '';

    postinstallPackage = let
      postinstallScript = pkgs.writeScript "postinstall.sh" ''
        #!/bin/bash

        # disable welcome screen
        touch "$3/var/db/.AppleSetupDone"
        touch "$3/private/var/db/.AppleSetupDone"

        # create user
        sysadminctl -addUser ${vmUser} -password ${vmPassword} -admin
        # add to sudoers
        cp "$3/etc/sudoers" "$3/etc/sudoers.orig"
        echo "${vmUser} ALL=(ALL) NOPASSWD: ALL" >> "$3/etc/sudoers"

        # enable SSH
        /bin/launchctl load -w /System/Library/LaunchDaemons/ssh.plist

        # poweroff
        shutdown -h now
      '';
    in pkgs.runCommand "bootstrap.pkg" {} ''
      mkdir -p flat/bootstrap.pkg
      # installable files
      mkdir root
      pushd root
      # no files so far
      find . | ${pkgs.cpio}/bin/cpio -o --format odc --owner 0:80 | gzip -c > ../flat/bootstrap.pkg/Payload
      popd
      # bom file
      ${pkgs.bomutils}/bin/mkbom -u 0 -g 80 root flat/bootstrap.pkg/Bom
      # scripts
      mkdir scripts
      cp ${postinstallScript} scripts/postinstall
      pushd scripts
      find . | ${pkgs.cpio}/bin/cpio -o --format odc --owner 0:80 | gzip -c > ../flat/bootstrap.pkg/Scripts
      popd
      # PackageInfo
      cp ${pkgs.writeText "PackageInfo" ''
        <?xml version="1.0" encoding="utf-8"?>
        <pkg-info overwrite-permissions="true" relocatable="false" identifier="coil.macos.bootstrap" postinstall-action="none" version="1" format-version="2" auth="root">
          <payload numberOfFiles="1" installKBytes="0"/>
          <scripts>
            <postinstall file="./postinstall"/>
          </scripts>
        </pkg-info>
      ''} flat/bootstrap.pkg/PackageInfo
      # Distribution
      cp ${pkgs.writeText "Distribution" ''
        <?xml version="1.0" encoding="utf-8"?>
        <installer-gui-script minSpecVersion="1">
          <pkg-ref id="coil.macos.bootstrap">
            <bundle-version/>
          </pkg-ref>
          <options customize="never" require-scripts="false" hostArchitectures="x86_64,arm64"/>
          <choices-outline>
            <line choice="default">
              <line choice="coil.macos.bootstrap"/>
            </line>
          </choices-outline>
          <choice id="default"/>
          <choice id="coil.macos.bootstrap" visible="false">
            <pkg-ref id="coil.macos.bootstrap"/>
          </choice>
          <pkg-ref id="coil.macos.bootstrap" version="1" onConclusion="none" installKBytes="0">#bootstrap.pkg</pkg-ref>
        </installer-gui-script>
      ''} flat/Distribution
      # package
      cd flat
      ${pkgs.xar}/bin/xar --compression none -cf $out *
    '';

    initialImage = pkgs.runCommand "macos_${version}-image.qcow2" {} ''
      ${qemu}/bin/qemu-img create -f qcow2 $out 256G
      ${qemu}/bin/qemu-img create -f qcow2 installhdd.qcow2 16G
      ${runInstall "$out"}
      echo 'Waiting for install to finish...'
      timeout 1h tail --pid=$(<vm.pid) -f /dev/null
    '';

  in {
    inherit initialImage;
  };

  fetchPlist = url: let
    fixed = fixeds.fetchurl."${url}";
  in pkgs.runCommand "${fixed.name}.json" {} ''
    ${plist2json}/bin/plist2json < ${pkgs.fetchurl {
      inherit (fixed) url sha256 name;
    }} > $out
  '';

  osxkvm = pkgs.fetchgit {
    inherit (fixeds.fetchgit."https://github.com/kholia/OSX-KVM.git") url rev sha256;
    fetchSubmodules = false;
  };

  plist2json = pkgs.callPackage ./plist2json {};

  qemu = pkgs.qemu_kvm;
  libguestfs = pkgs.libguestfs-with-appliance.override {
    inherit qemu; # no need to use full qemu
  };

  # macOS Monterey
  majorVersion = "12";
  latestVersion = lib.pipe allOSInstallers [
    (lib.filter (info: lib.hasPrefix "${majorVersion}." info.version && builtins.compareVersions info.version majorVersion >= 0))
    (map (info: info.version))
    (lib.sort (a: b: builtins.compareVersions a b > 0))
    lib.head
  ];
  packages = macosPackages {
    version = latestVersion;
    baseSystemVersion = "10.15.7"; # latest Catalina
  };

  vmUser = "vagrant";
  vmPassword = "vagrant";

  allInstallersDistributions = lib.pipe allOSInstallers [
    (map (o: "${o.distributionJson}\n"))
    lib.concatStrings
    (pkgs.writeText "allInstallersDistributions")
  ];

  touch = {
    inherit catalogPlist allInstallersDistributions;
    inherit (packages) initialImage;

    autoUpdateScript = toolchain.autoUpdateFixedsScript fixedsFile;
  };
}
