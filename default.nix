{ pkgs ? import <nixpkgs> {}
, lib ? pkgs.lib
, toolchain
, xml ? toolchain.utils.xml
, fixedsFile ? ./fixeds.json
, fixeds ? lib.importJSON fixedsFile
}:

rec {
  catalogVersions = "13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard";

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
        meta = metaUnfree;
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

  allCLToolsInstallers = lib.pipe products [
    (lib.filterAttrs (key: product: lib.strings.match ".+CLTools.+" (product.ServerMetadataURL or "") != null))
    (lib.mapAttrsToList (key: product: let
      metadataPlist = fetchPlist product.ServerMetadataURL;
      metadata = lib.importJSON metadataPlist;
      title = metadata.localization.English.title;
      version = metadata."CFBundleShortVersionString";
    in {
      inherit key title version metadataPlist;
    }))
  ];

  clToolsInstallersByVersion = lib.pipe allCLToolsInstallers [
    # group by version
    (lib.groupBy (p: p.version))
    # filter out betas
    (lib.mapAttrs (_version: installers: lib.filter (installer: lib.strings.match ".*beta.*" installer.title == null) installers))
    # check single package
    (lib.mapAttrs (version: installers: assert lib.length installers == 1; products."${(lib.head installers).key}"))
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
        meta = metaUnfree;
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
      meta = metaUnfree;
    };

    iso = pkgs.runCommand "fullInstaller.iso" {} ''
      mkdir -p iso/installer.pkg
      pushd iso/installer.pkg
      ${installerScript osInstallersByVersion."${version}"}
      popd
      ${pkgs.cdrtools}/bin/mkisofs -quiet -iso-level 3 -udf -follow-links -o $out iso
    '';

    runVMScript =
    { name ? "macos"
    , hdd
    , vars
    , iso ? null
    , qmpSocket ? null
    , opts ? ""
    }: pkgs.writeScript "run.sh" (''
      ${qemu}/bin/qemu-system-x86_64 \
      -name ${name} \
      -enable-kvm \
      -pidfile vm.pid \
      -smp 4,cores=2,threads=2,sockets=1 \
      -m 8G \
      -cpu Penryn,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,+pcid,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check \
      -machine q35 \
      -device isa-applesmc,osk="ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc" \
      -smbios type=2 \
      -device VGA,vgamem_mb=128 \
      -rtc base=utc,clock=vm \
      -usb -device usb-kbd -device usb-mouse \
      -device usb-ehci,id=ehci \
      -device ich9-ahci,id=sata \
      -drive if=pflash,format=raw,readonly=on,file=${osxkvm}/OVMF_CODE.fd \
      -drive if=pflash,format=qcow2,file=${vars} \
      -drive id=OpenCoreBoot,if=none,snapshot=on,format=qcow2,file=${osxkvm}/OpenCore/OpenCore.qcow2 \
      -device ide-hd,bus=sata.0,drive=OpenCoreBoot \
      -drive id=MacHDD,if=none,file=${hdd},format=qcow2,cache=unsafe,discard=unmap,detect-zeroes=unmap \
      -device ide-hd,bus=sata.1,drive=MacHDD \
      -netdev user,id=net0,hostfwd=tcp::20022-:22 \
      -device virtio-net,netdev=net0,id=net0 \
    '' +
    lib.optionalString (qmpSocket != null) ''
      -qmp unix:${qmpSocket},server,nowait \
    '' +
    lib.optionalString (iso != null) ''
      -cdrom ${iso} \
    '' + opts + ''
      -vnc unix:vnc.socket -daemonize
    '');

    runInstall = { hdd, vars }: pkgs.writeScript "runInstall.sh" ''
      set -eu
      mkdir -p floppy/scripts
      cp ${initScript} floppy/init.sh
      cp ${postinstallPackage} floppy/bootstrap.pkg
      ${runVMScript {
        inherit hdd vars iso;
        qmpSocket = "vm.socket";
        opts = ''
          -drive id=InstallHDD,if=none,file=installhdd.qcow2,format=qcow2,cache=unsafe,discard=unmap,detect-zeroes=unmap \
          -device ide-hd,bus=sata.2,drive=InstallHDD \
          -drive id=InstallMediaBase,if=none,format=dmg,snapshot=on,file=${baseSystemImage} \
          -device ide-hd,bus=sata.3,drive=InstallMediaBase \
          -drive id=ScriptMedia,if=none,file=fat:rw:$PWD/floppy,format=vvfat,cache=unsafe \
          -device ide-hd,bus=sata.5,drive=ScriptMedia \
        '';
      }}

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
        --agreetolicense --nointeraction --forcequitapps \
        --volume /Volumes/MacHDD \
        --installpackage '/Volumes/QEMU VVFAT/bootstrap.pkg'
    '';

    postinstallPackage = let
      postinstallScript = pkgs.writeScript "postinstall.sh" ''
        #!/bin/bash

        set -eu

        PlistBuddy=/usr/libexec/PlistBuddy
        target_ds_node="$3/private/var/db/dslocal/nodes/Default"

        # disable welcome screen
        touch "$3/private/var/db/.AppleSetupDone"
        touch "$3/var/db/.AppleSetupDone"

        # disable power saving stuff
        pmset -a displaysleep 0 disksleep 0 sleep 0 womp 0
        defaults -currentHost write com.apple.screensaver idleTime 0

        # create user
        sysadminctl -addUser ${vmUser} -password ${vmUserPassword} -admin
        # add to sudoers
        cp "$3/etc/sudoers" "$3/etc/sudoers.orig"
        echo "${vmUser} ALL=(ALL) NOPASSWD: ALL" >> "$3/etc/sudoers"

        # add user to admin group memberships
        USER_GUID=$($PlistBuddy -c 'Print :generateduid:0' "$target_ds_node/users/${vmUser}.plist")
        USER_UID=$($PlistBuddy -c 'Print :uid:0' "$target_ds_node/users/${vmUser}.plist")
        $PlistBuddy -c 'Add :groupmembers: string '"$USER_GUID" "$target_ds_node/groups/admin.plist"
        # add user to SSH SACL group membership
        ssh_group="$target_ds_node/groups/com.apple.access_ssh.plist"
        $PlistBuddy -c 'Add :groupmembers array' "$ssh_group"
        $PlistBuddy -c 'Add :groupmembers:0 string '"$USER_GUID" "$ssh_group"
        $PlistBuddy -c 'Add :users array' "$ssh_group"
        $PlistBuddy -c 'Add :users:0 string ${vmUser}' "$ssh_group"

        # enable SSH
        /bin/launchctl load -w /System/Library/LaunchDaemons/ssh.plist
        cp /System/Library/LaunchDaemons/ssh.plist /Library/LaunchDaemons/ssh.plist
        /usr/libexec/plistbuddy -c "set Disabled FALSE" /Library/LaunchDaemons/ssh.plist
        # authorize key
        mkdir -p /Users/${vmUser}/.ssh
        echo ${lib.escapeShellArg (builtins.readFile "${vmUserKey}/key.pub")} > /Users/${vmUser}/.ssh/authorized_keys
        chown -R ${vmUser} /Users/${vmUser}/.ssh
        chmod 700 /Users/${vmUser}/.ssh
        chmod 600 /Users/${vmUser}/.ssh/authorized_keys

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

    initialImage = pkgs.runCommand "macos_${version}.qcow2" {} ''
      mkdir $out
      ${qemu}/bin/qemu-img create -qf qcow2 $out/hdd.qcow2 256G
      ${qemu}/bin/qemu-img create -qf qcow2 installhdd.qcow2 128G
      ${qemu}/bin/qemu-img convert -f raw -O qcow2 ${osxkvm}/OVMF_VARS-1024x768.fd $out/vars.qcow2
      ${runInstall {
        hdd = "$out/hdd.qcow2";
        vars = "$out/vars.qcow2";
      }}
      echo 'Waiting for install to finish...'
      timeout 1h tail --pid=$(<vm.pid) -f /dev/null
    '';

    step =
    { baseImage ? initialImage
    , name ? "macos_${version}-step"
    , extraMount ? null
    , extraMountIn ? true
    , extraMountOut ? true
    , beforeScript ? ""
    , command
    , afterScript ? ""
    , fastHddOut ? !(extraMount != null && extraMountOut) && afterScript == ""
    }: let
      ssh_run = command: ssh_run_raw (lib.escapeShellArg command);
      ssh_run_raw = rawCommand: "${pkgs.openssh}/bin/ssh -o StrictHostKeyChecking=no -o PubkeyAuthentication=yes -o PasswordAuthentication=no -i ${vmUserKey}/key -p 20022 ${vmUser}@localhost ${rawCommand}";
      scp_to = src: dst: let
        srcArg = lib.escapeShellArg src;
        dstArg = lib.escapeShellArg dst;
      in ''tar -chf - --mode=u+rw -C "$(dirname "$(readlink -f ${srcArg})")" "$(basename "$(readlink -f ${srcArg})")" | ${ssh_run "tar -xf - --strip-components=1 -C ${dstArg}"}'';
      scp_from = src: dst: let
        srcArg = lib.escapeShellArg src;
        dstArg = lib.escapeShellArg dst;
      in "${ssh_run ''tar -chf - -C "$(dirname ${srcArg})" "$(basename ${srcArg})"''} | tar -xf - --strip-components=1 -C ${dstArg}";
      hdd = if fastHddOut then "$out/hdd.qcow2" else "hdd.qcow2";
      vars = if fastHddOut then "$out/vars.qcow2" else "vars.qcow2";
      mountIn = "/Volumes/MountHDD/in";
      mountOut = "/Volumes/MountHDD/out";
    in pkgs.runCommand name {}
    ''
      set -eu
      ${lib.optionalString fastHddOut ''
        mkdir $out
      ''}
      OK=""
      for i in {1..3}
      do
        ${qemu}/bin/qemu-img create -qf qcow2 -b ${baseImage}/hdd.qcow2 -F qcow2 ${hdd}
        ${qemu}/bin/qemu-img create -qf qcow2 mounthdd.qcow2 128G
        ${qemu}/bin/qemu-img create -qf qcow2 -b ${baseImage}/vars.qcow2 -F qcow2 ${vars}
        echo 'Starting VM...'
        ${runVMScript {
          inherit hdd vars;
          opts = ''
            -drive id=MountHDD,if=none,file=mounthdd.qcow2,format=qcow2,cache=unsafe,discard=unmap,detect-zeroes=unmap \
            -device ide-hd,bus=sata.2,drive=MountHDD \
          '';
        }}
        for j in {1..10}
        do
          if ${ssh_run "true"}
          then
            OK=ok
            echo 'Connected.'
            break 2
          fi
          sleep 1
        done
        kill -9 $(<vm.pid)
        tail --pid=$(<vm.pid) -f /dev/null
        rm ${hdd} mounthdd.qcow2 .ssh/known_hosts
        echo "Connecting to VM: attempt $i failed"
      done
      if [ "$OK" != 'ok' ]
      then
        echo 'Connecting to VM: all attempts failed'
        exit 1
      fi
      ${beforeScript}
      ${lib.optionalString (extraMount != null && (extraMountIn || extraMountOut)) ''
        for i in {1..60}
        do
          MOUNT_HDD=$(${ssh_run "diskutil list -plist"} | ${plist2json}/bin/plist2json | ${pkgs.jq}/bin/jq -r '.AllDisksAndPartitions[] | select(.Content == "").DeviceIdentifier')
          if [ "$MOUNT_HDD" != "" ]
          then
            break
          fi
          echo "Finding mount disk attempt $i failed"
          sleep 1
        done
        if [ "$MOUNT_HDD" == "" ]
        then
          echo 'Failed to find mount disk'
          exit 1
        fi
        ${lib.pipe ''
          diskutil eraseDisk APFSX MountHDD GPT /dev/MOUNT_HDD
          mkdir ${mountIn} ${mountOut}
        '' [
          lib.escapeShellArg
          (lib.replaceStrings ["MOUNT_HDD"] ["'$MOUNT_HDD'"])
          ssh_run_raw
        ]}
      ''}
      ${lib.optionalString (extraMount != null && extraMountIn) ''
        echo 'Copying extra mount data in...'
        ${scp_to extraMount mountIn}
        rm -r ${lib.escapeShellArg extraMount}
      ''}
      ${lib.optionalString (extraMount != null && extraMountOut) ''
        ${ssh_run ''
          mkdir -p ${mountOut}
        ''}
      ''}
      ${ssh_run ''
        set -eu
        echo 'Performing command...'
        ${command {
          inherit mountIn mountOut;
        }}
      ''}
      ${lib.optionalString (extraMount != null && extraMountOut) ''
        echo 'Copying extra mount data out...'
        mkdir ${extraMount}
        ${scp_from mountOut extraMount}
      ''}
      echo 'Shutting down VM...'
      ${ssh_run ''
        sudo shutdown -h now
      ''} || true
      timeout 60s tail --pid=$(<vm.pid) -f /dev/null
      ${afterScript}
    '';

    clToolsImage = { clToolsVersion ? latestCLToolsVersion }: step {
      name = "macos_${version}_cltools_${clToolsVersion}.qcow2";
      extraMount = "data";
      extraMountOut = false;
      beforeScript = ''
        mkdir data
        pushd data
        ${installerScript clToolsInstallersByVersion."${clToolsVersion}"}
        popd
      '';
      command = { mountIn, ... }: ''
        sudo installer -pkg ${mountIn}/*.dist -target /Applications
      '';
    };

  in {
    inherit initialImage step clToolsImage;
  };

  fetchPlist = url: let
    fixed = fixeds.fetchurl."${url}";
  in pkgs.runCommand "${fixed.name}.json" {} ''
    ${plist2json}/bin/plist2json < ${pkgs.fetchurl {
      inherit (fixed) url sha256 name;
      meta = metaUnfree;
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
  majorOSVersion = "13";
  latestOSVersion = lib.pipe allOSInstallers [
    (lib.filter (info: lib.hasPrefix "${majorOSVersion}." info.version && builtins.compareVersions info.version majorOSVersion >= 0))
    (lib.sort (a: b: [(builtins.compareVersions a.version b.version) a.date] > [0 b.date]))
    lib.head
    (info: info.version)
  ];
  packages = macosPackages {
    version = latestOSVersion;
    baseSystemVersion = "10.15.7"; # latest Catalina
  };

  latestCLToolsVersion = lib.pipe allCLToolsInstallers [
    (map (info: info.version))
    (lib.sort (a: b: builtins.compareVersions a b > 0))
    lib.head
  ];

  vmUser = "vagrant";
  vmUserPassword = "vagrant";

  vmUserKey = pkgs.runCommand "userKey" {} ''
    mkdir $out
    ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -f $out/key -C ${vmUser}
  '';

  allInstallersMetadatas = let
    installers
      =  map (o: "${o.distributionJson}\n") allOSInstallers
      ++ map (o: "${o.metadataPlist}\n") allCLToolsInstallers
      ;
  in lib.pipe installers [
    lib.concatStrings
    (pkgs.writeText "allInstallersMetadatas")
  ];

  metaUnfree = {
    license = lib.licenses.unfree;
  };

  touch = {
    inherit catalogPlist allInstallersMetadatas vmUserKey;
    inherit (packages) initialImage;
    clToolsImage = packages.clToolsImage {};

    #autoUpdateScript = toolchain.autoUpdateFixedsScript fixedsFile;
  };
}
