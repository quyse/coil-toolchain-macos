# macOS support for Coil Toolchain

This repo is about building and using macOS VMs from Nix on Linux.

## Other projects

* [kholia/OSX-KVM](https://github.com/kholia/OSX-KVM) - maintains OpenCore/OVMF* binaries to boot VM with base image
* [timsutton/osx-vm-templates](https://github.com/timsutton/osx-vm-templates) - has [prepare_iso.sh](https://github.com/timsutton/osx-vm-templates/blob/master/prepare_iso/prepare_iso.sh) script which builds an ISO for automated install by combining base image with InstallESD.dmg and other files, and injecting additional post-install scripts. The script itself runs on macOS.
* [myspaghetti/macos-virtualbox](https://github.com/myspaghetti/macos-virtualbox) - semi-automated script for building VirtualBox macOS VM. Combines base image with other installer files by running a script in a VM, then runs VM second time using combined installer. Uses sending key presses for interaction with VM, and Tesseract-based OCR for figuring out when VM is booted.
* [New Adventures in Automating OS X Installs with startosinstall](https://macops.ca/new-adventures-in-automating-os-x-installs-with-startosinstall/) - outlines use of `startosinstall` script

## Legality

Links in the [Is This Legal?](https://github.com/kholia/OSX-KVM#is-this-legal) README section of the great [kholia/OSX-KVM](https://github.com/kholia/OSX-KVM) project may be of interest.
