{ pkgs ? import <nixpkgs> {}
, lib ? pkgs.lib
, toolchain
, xml ? toolchain.utils.xml
, fixedsFile ? ./fixeds.json
, fixeds ? lib.importJSON fixedsFile
, dryRunFixeds ? false
}:

rec {
  catalogVersions = "14-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard";

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
      distributionXml = fetchFixed {
        url = product.Distributions.English;
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
    # filter out versions with no installers
    (lib.filterAttrs (_version: installers: lib.length installers > 0))
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
      fixed = fetchFixed {
        inherit url;
        skipOnDryRun = true;
      };
    in ''
      ln -s ${fixed} ${lib.escapeShellArg (nameOfFixed fixed)}
    ''))
    (lib.sort (a: b: a < b))
    lib.concatStrings
  ];

  macosPackages = { version, baseSystemVersion }: let
    baseSystem = osInstallersByVersion."${baseSystemVersion}";
    findSinglePackage = name: with lib;
      (findSingle (p: last (splitString "/" p.URL) == name) null null baseSystem.Packages).URL;
    baseSystemImage = fetchFixed {
      url = findSinglePackage "BaseSystem.dmg";
      skipOnDryRun = true;
    };

    iso = runCommandOrSkipOnDryRun "fullInstaller.iso" {} ''
      mkdir -p iso/installer.pkg
      pushd iso/installer.pkg
      ${installerScript osInstallersByVersion."${version}"}
      popd
      ln -s ${initScript} iso/init.sh
      ln -s ${postinstallPackage} iso/bootstrap.pkg
      ${pkgs.cdrtools}/bin/mkisofs -quiet -iso-level 3 -udf -follow-links -o $out iso
    '';

    runVMScript =
    { name ? "macos"
    , hdd
    , vars
    , iso ? null
    , qmpSocket ? null
    , opts ? []
    }: pkgs.writeShellScript "run.sh" (''
      ${qemu}/bin/qemu-system-x86_64 ${lib.concatStringsSep " " ([
        "-name ${name}"
        "-enable-kvm"
        "-pidfile vm.pid"
        "-smp 4,cores=2,threads=2,sockets=1"
        "-m 8G"
        "-cpu Penryn,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,+pcid,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check"

        # file-backed memory
        "-machine type=q35,accel=kvm,memory-backend=pc.ram"
        "-object memory-backend-file,id=pc.ram,size=8G,mem-path=pc.ram,prealloc=off,share=on,discard-data=on"

        # magic string
        "-device isa-applesmc,osk='ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc'"

        "-smbios type=2"
        "-device vmware-svga"
        "-rtc base=utc,clock=vm"
        "-usb -device usb-kbd -device usb-mouse"
        "-device usb-ehci,id=ehci"
        "-device nec-usb-xhci,id=xhci"
        "-global nec-usb-xhci.msi=off"
        "-global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off"
        "-device ich9-ahci,id=sata"
        "-drive if=pflash,format=raw,readonly=on,file=${osxkvm}/OVMF_CODE.fd"
        "-drive if=pflash,format=qcow2,file=${vars}"
        "-drive id=OpenCoreBoot,if=none,snapshot=on,format=qcow2,file=${osxkvm}/OpenCore/OpenCore.qcow2"
        "-device ide-hd,bus=sata.0,drive=OpenCoreBoot,model=OpenCoreBoot"
        "-drive id=MacHDD,if=none,file=${hdd},format=qcow2,cache=unsafe,discard=unmap,detect-zeroes=unmap"
        "-device ide-hd,bus=sata.1,drive=MacHDD,model=MacHDD"
        "-netdev user,id=net0,hostfwd=tcp:127.0.0.1:${vmSshPort}-:22"
        "-device virtio-net,netdev=net0,id=net0"
      ]
      ++ lib.optional (qmpSocket != null) "-qmp unix:${qmpSocket},server,nowait"
      ++ lib.optionals (iso != null) [
        "-drive id=CDROM,if=none,file=${iso},snapshot=on"
        "-device ide-hd,bus=sata.4,drive=CDROM,model=CDROM"
      ]
      ++ opts
      ++ [
        "-vnc unix:vnc.socket"
        "-daemonize"
      ])}
    '');

    runInstall = { hdd, vars }: pkgs.writeShellScript "runInstall.sh" ''
      set -eu
      ${runVMScript {
        inherit hdd vars iso;
        qmpSocket = "vm.socket";
        opts = [
          "-drive id=InstallHDD,if=none,file=installhdd.qcow2,format=qcow2,cache=unsafe,discard=unmap,detect-zeroes=unmap"
          "-device ide-hd,bus=sata.2,drive=InstallHDD,model=InstallHDD"
          "-drive id=InstallMediaBase,if=none,format=dmg,snapshot=on,file=${baseSystemImage}"
          "-device ide-hd,bus=sata.3,drive=InstallMediaBase,model=InstallMediaBase"
        ];
      }}

      PATH=$PATH:${pkgs.tesseract4}/bin SOCKET_PATH=vm.socket ${pkgs.nodejs}/bin/node ${./init.js}
    '';

    initScript = pkgs.writeScript "initScript.sh" ''
      # format drives
      processDisk () {
        diskutil info -plist $1 > /tmp/sizeinfo
        MediaName="$(/usr/libexec/PlistBuddy -c 'Print :MediaName' /tmp/sizeinfo)"
        if [ "$MediaName" = 'MacHDD' ]
        then
          echo "Formatting MacHDD ($1)..."
          diskutil eraseDisk APFSX MacHDD GPT $1
        fi
        if [ "$MediaName" = 'InstallHDD' ]
        then
          echo "Formatting InstallHDD ($1)..."
          diskutil eraseDisk APFSX InstallHDD GPT $1
        fi
      }
      # drives should have small indexes
      processDisk /dev/disk0
      processDisk /dev/disk1
      processDisk /dev/disk2
      processDisk /dev/disk3

      # work around bug in installer postinstall scripts
      ln -s /Volumes/InstallHDD/Applications /Volumes/InstallHDDApplications
      # unpack installer
      installer -pkg /Volumes/CDROM/installer.pkg/*.dist -target /Volumes/InstallHDD
      # run installer
      /Volumes/InstallHDD/Applications/Install\ macOS\ *.app/Contents/Resources/startosinstall \
        --agreetolicense --nointeraction --forcequitapps \
        --volume /Volumes/MacHDD \
        --installpackage /Volumes/CDROM/bootstrap.pkg
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
      ${pkgs.bomutils.overrideAttrs (attrs: {
        # causes runtime crash
        hardeningDisable = ["fortify3"];
      })}/bin/mkbom -u 0 -g 80 root flat/bootstrap.pkg/Bom
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

    initialImage = runCommandOrSkipOnDryRun "macos_${version}.qcow2" {} ''
      set -eu
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
    , impure ? false
    }: let
      ssh_run = command: ssh_run_raw (lib.escapeShellArg command);
      ssh_run_raw = rawCommand: "${pkgs.openssh}/bin/ssh -o StrictHostKeyChecking=no -o PubkeyAuthentication=yes -o PasswordAuthentication=no -i ${vmUserKey}/key -p ${vmSshPort} ${vmUser}@127.0.0.1 ${rawCommand}";
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
    in runCommandOrSkipOnDryRun name (if impure then { __impure = true; } else {}) ''
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
          opts = [
            "-drive id=MountHDD,if=none,file=mounthdd.qcow2,format=qcow2,cache=unsafe,discard=unmap,detect-zeroes=unmap"
            "-device ide-hd,bus=sata.2,drive=MountHDD,model=MountHDD"
          ];
        }}
        for j in {1..30}
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
        rm -f ${hdd} mounthdd.qcow2 .ssh/known_hosts
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
    fixed = fetchFixed {
      inherit url;
    };
  in pkgs.runCommand "${nameOfFixed fixed}.json" {} ''
    ${plist2json}/bin/plist2json < ${fixed} > $out
  '';

  osxkvm = pkgs.fetchgit {
    inherit (fixeds.fetchgit."https://github.com/kholia/OSX-KVM.git") url rev sha256;
    fetchSubmodules = false;
  };

  plist2json = pkgs.callPackage ./plist2json {};

  qemu = pkgs.qemu_kvm;

  # macOS Ventura
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

  latestCLToolsVersion = lib.pipe clToolsInstallersByVersion [
    (lib.mapAttrsToList (version: _installer: version))
    (lib.sort (a: b: builtins.compareVersions a b > 0))
    lib.head
  ];

  vmUser = "vagrant";
  vmUserPassword = "vagrant";
  # just some random port
  # TODO: actually use random port or use hostfwd unix:
  # (if it ever gets implemented https://gitlab.com/qemu-project/qemu/-/issues/347)
  # in impure mode this port is opened on host's localhost, and so may conflict
  vmSshPort = "43278";

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

  fetchFixed = { url, skipOnDryRun ? false }: if dryRunFixeds
    then let
      fileExt = lib.last (lib.splitString "." url);
      ignoreEtag = {
        dist = true;
        plist = true;
        smd = true;
      }."${fileExt}" or false;
    in builtins.trace "FIXED_FETCHURL: ${builtins.toJSON ({
      inherit url;
      ignore_last_modified = true;
    } // lib.optionalAttrs ignoreEtag {
      ignore_etag = true;
    })}" (if skipOnDryRun then pkgs.writeText "fetchFixed_dryRun" url else builtins.fetchurl url)
    else pkgs.fetchurl {
      inherit (fixeds.fetchurl."${url}") url sha256 name;
      meta = metaUnfree;
    }
  ;
  runCommandOrSkipOnDryRun = if dryRunFixeds
    then name: env: script: pkgs.writeText "runCommandOrSkipOnDryRun_dryRun" script
    else pkgs.runCommand
  ;
  nameOfFixed = fixed: if builtins.typeOf fixed == "string"
    then lib.last (lib.splitString "/" fixed)
    else fixed.name;

  touch = {
    inherit catalogPlist allInstallersMetadatas vmUserKey;
    inherit (packages) initialImage;
    clToolsImage = packages.clToolsImage {};

    autoUpdateScript_disabled = pkgs.writeShellScript "autoUpdateScript" ''
      set -euo pipefail

      nix build -L --impure --expr ${lib.escapeShellArg ''
        (import ${./.} {
          toolchain = import ${toolchain.path} {};
          dryRunFixeds = true;
        }).touch
      ''} --no-link 2>&1 \
      | ${pkgs.gnugrep}/bin/grep -F FIXED_FETCHURL \
      | ${pkgs.gnused}/bin/sed -Ee 's/^.*FIXED_FETCHURL: (.+)$/\1/' \
      | ${pkgs.jq}/bin/jq -sS --slurpfile fixeds ${fixedsFile} ${lib.escapeShellArg ''
        $fixeds[0].fetchurl as $fetchurl_old |
        $fixeds[0] + {
          fetchurl: map({
            key: .url,
            value: (if $fetchurl_old[.url]
              then $fetchurl_old[.url] + .
              else .
            end)
          }) | from_entries
        }
      ''} > fixeds1.json

      ${toolchain.autoUpdateFixedsScript "./fixeds1.json"}

      rm fixeds1.json
    '';
  };
}
