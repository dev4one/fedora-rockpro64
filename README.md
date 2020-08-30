# Fedora for RockPro64
## Summary
Flashes a MicroSD Card with a Fedora RootFS and an Ayufan UBoot&amp;Kernel for a RockPro64 board

## Prerequisites
Running Linux (preferably Fedora) distribution with MicroSD card inserted

## Flashing the distribution
The install.sh uses the [Ayufan Debian](https://github.com/ayufan-rock64/linux-build/releases) release, by default the [Buster 0.10.12](https://github.com/ayufan-rock64/linux-build/releases/download/0.10.12/buster-minimal-rockpro64-0.10.12-1184-arm64.img.xz) image

and a Fedora 32 aarch64 image, by default the Workstation spin [Fedora Workstation 32 aarch64 (https://download.fedoraproject.org/pub/fedora/linux/releases/32/Workstation/aarch64/images/Fedora-Workstation-32-1.6.aarch64.raw.xz)


To create a bootable MicroSD card with Fedora 32 simply run:

```
bash install.sh
```

The whole process takes about 5 minutes or so. After is completes, boot using the new card and login with root/fedora and finish the install using

```
bash /root/finish-install.sh
```

This will prompt you to change the root password.

## Other options
Use -h to list all the available options for the script (for example to use the Workstation Fedora spin rather than the Minimal), e.g.
```
bash install.sh -h
```

## Credits
This is heavily inspired/influenced from the CentOS image creation script from Project31 [Project31](https://project31.github.io/pine64/)

All kudos goes to Project31 

