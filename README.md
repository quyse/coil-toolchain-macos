# macOS support for Coil Toolchain

This repo is about building and using macOS VMs from Nix on Linux.

## Other projects

* [kholia/OSX-KVM](https://github.com/kholia/OSX-KVM) - maintains OpenCore/OVMF* binaries to boot VM with base image
* [timsutton/osx-vm-templates](https://github.com/timsutton/osx-vm-templates) - has [prepare_iso.sh](https://github.com/timsutton/osx-vm-templates/blob/master/prepare_iso/prepare_iso.sh) script which builds an ISO for automated install by combining base image with InstallESD.dmg and other files, and injecting additional post-install scripts. The script itself runs on macOS.
* [myspaghetti/macos-virtualbox](https://github.com/myspaghetti/macos-virtualbox) - semi-automated script for building VirtualBox macOS VM. Combines base image with other installer files by running a script in a VM, then runs VM second time using combined installer. Uses sending key presses for interaction with VM, and Tesseract-based OCR for figuring out when VM is booted.
* [New Adventures in Automating OS X Installs with startosinstall](https://macops.ca/new-adventures-in-automating-os-x-installs-with-startosinstall/) - outlines use of `startosinstall` script
* https://github.com/munki/macadmin-scripts/blob/main/installinstallmacos.py
* https://github.com/sickcodes/Docker-OSX

## Keeping fixeds up-to-date

`refresh_fixeds` script from Coil Toolchain is used for updating `fixeds.json`. Note that `etag` and `last-modified` headers returned by Apple's servers are not stable - may vary between requests, probably when hitting different servers behind balancer (as if somebody just puts a bunch of files on a bunch of servers with a script, at different times and with different etag calculation modes, very much totally legit way of doing a CDN).

## Legality

Links in the [Is This Legal?](https://github.com/kholia/OSX-KVM#is-this-legal) README section of the [kholia/OSX-KVM](https://github.com/kholia/OSX-KVM) project may be of interest.
