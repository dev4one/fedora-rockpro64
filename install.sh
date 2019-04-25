#!/bin/bash

# Default value used if no arguments are provided
targetDev=sdb
fedoraImage=Fedora-Minimal-29-1.2.aarch64.raw
debianImage=stretch-minimal-rockpro64-0.8.0rc9-1120-arm64.img
rootSize=7500
efiPart=6
rootPart=7

rootfsDir=${PWD}/rootfs
fedoraDir=${PWD}/fedora
ayufanDir=${PWD}/ayufan

if   ! test -d ${rootfsDir} \
  || ! test -d ${fedoraDir} \
  || ! test -d ${ayufanDir}
then
  echo "Must be run from the top level GIT directory! - Aborting"
  exit 1
fi

usage() {
  echo ""
  echo "Usage:  $(basename ${0})"
  echo "            [--target=<targetdev>]"
  echo "            [--fedora-image=<FedoareImagePath>]"
  echo "            [--debian-image=<AyufanDebianImagePath>]"
  echo "            [--root-size=<RootPartSizeMB>]"
  echo ""
}
 

while [[ "${1}" ]]
do
  case "${1}" in
    --target=*|--target|-t)
      if [[ "${1:8:1}" == "=" ]]
      then
        targetDev="${1:9}"
      else
        targetDev="${2}"
        shift
      fi
      targetDev="${targetDev/\/dev\//}"
      if [[ "${targetDev:0:4}" == "loop" ]]
      then
        efiPart="p${efiPart}"
        rootPart="p${rootPart}"
      fi
    ;;
    --fedora-image=*|--fedora-image|-fi)
      if [[ "${1:14:1}" == "=" ]]
      then
        fedoraImage="${1:15}"
      else
        fedoraImage="${2}"
        shift
      fi
    ;;
    --debian-image=*|--debian-image|-di)
      if [[ "${1:14:1}" == "=" ]]
      then
        debianImage="${1:15}"
      else
        debianImage="${2}"
        shift
      fi
    ;;
    --root-size=*|--root-size|-s)
      if [[ "${1:11:1}" == "=" ]]
      then
        rootSize="${1:12}"
      else
        rootSize="${2}"
        shift
      fi
    ;;
    *)
      usage
      exit 1
    ;;
  esac
  shift
done

cat banner.txt

echo "WARNING: Proceeding will result in the loss of ALL data on device /dev/${targetDev} !! "
read -p "Are you sure you want to proceed [y,N]? " -r
echo 
if [[ ! ${REPLY} =~ ^[yY]$ ]] 
then
  echo "Leaving flash process before any harm was done"
  usage
  exit 0
fi

if mount | grep /dev/${targetDev} > /dev/null
then
  echo "Target device is still mounted! - Aborting"
  exit 2
fi

if ! test -f ${debianImage}
then
  echo "Debian Image (${debianImage}) not found! - Aborting"
  exit 1
fi

if [[ "${debianImage/*img./}" == "xz" ]]
then
  echo "Expanding Debian Image"
  xz -k -d ${debianImage}
  debianImage="${debianImage/.xz/}"
fi

if test ! -f ${fedoraImage}
then
  echo "Fedora Image (${fedoraImage}) not found! - Aborting"
  exit 1
fi

if [[ "${fedoraImage/*img./}" == "xz" ]]
then
  echo "Expanding Fedora Image"
  xz -k -d ${fedoraImage}
  fedoraImage="${fedoraImage/.xz/}"
fi

echo ""
echo "Flashing Debian to '${targetDev}'"

dd bs=1MB if=${debianImage} of=/dev/${targetDev} status=progress
sync
partprobe --summary /dev/${targetDev}
sync
sgdisk --move-second-header /dev/${targetDev}
sync

echo ""
echo "Resize root partition (7) to ${rootSize}MB"
echo "resizepart 7 ${rootSize}\n\q\n" | parted /dev/${targetDev}
sync
partprobe --summary /dev/${targetDev}
sleep 2

echo ""
echo "Waiting for rootfs filesystem"
max=30
while [[ ${max} -gt 0 ]]
do
  test -b /dev/${targetDev}${rootPart} && break
  sync
  sleep 1
  $((max--))
done

e2fsck -f /dev/${targetDev}${rootPart}
resize2fs /dev/${targetDev}${rootPart}
sync

echo ""
echo "Mounting $(basename ${rootfsDir}) filesystem"
mount /dev/${targetDev}${rootPart} ${rootfsDir}

echo "Saving Ayufan Boot and Kernel"
tar --create \
    --acls \
    --checkpoint=100 \
    --checkpoint-action=dot \
    --xattrs \
    --xz \
    --file=${ayufanDir}/boot-saved.tar.xz \
    --directory=${rootfsDir} \
    --exclude=filesystem.packages* \
    boot \
    etc/firmware \
    lib/modules \
    lib/firmware \
    vendor

rm --force \
   --recursive \
   ${rootfsDir}/*

loopDev=$(losetup --find \
                  --partscan \
                  --show \
                  --read-only \
                  ${fedoraImage})

mount --options ro \
      ${loopDev}p3 ${fedoraDir}

echo ""
echo "Populating Fedora"
tar --create \
    --acls \
    --xattrs \
    --file=- \
    --directory=${fedoraDir} \
    --exclude=boot \
    --exclude=lib/firmware \
    --exclude=lib/modules \
    . \
  | tar --extract \
        --acls \
        --checkpoint=1000 \
        --checkpoint-action=dot \
        --same-permissions \
        --same-owner \
        --same-order \
        --xattrs \
        --file=- \
        --directory=${rootfsDir} \
        --keep-directory-symlink \
        --numeric-owner 

if   test -f /etc/os-release \
  && [[ ! -z "$(grep 'ID.*=.*fedora' /etc/os-release)" ]]
then
  echo ""
  echo "Removing the Fedora Kernel"
  fedoraKernelVersions=$(rpm --root ${rootfsDir} \
                             --query \
                             --queryformat '[%{VERSION} ]' \
                             --all \
                             name='kernel-core*')
  fedoraKernelPkgs=$(for version in ${fedoraKernelVersions}
                     do
                       rpm --root ${rootfsDir} \
                           --query \
                           --all \
                           name='kernel*' version=${version} \
                         | grep -v 'kernel-core-' ; \
                     done)
  rpm --root ${rootfsDir} \
      --erase \
      --nodeps \
      --noscripts \
      --verbose \
      ${fedoraKernelPkgs} 2>/dev/null
  echo 'excludepkgs=kernel-*' >>${rootfsDir}/etc/dnf/dnf.conf
fi

echo ""
echo "Adding kernel artifacts with Ayufan"
tar --extract \
    --acls \
    --checkpoint=100 \
    --checkpoint-action=dot \
    --same-permissions \
    --same-owner \
    --same-order \
    --xattrs \
    --xz \
    --file=${ayufanDir}/boot-saved.tar.xz \
    --directory=${rootfsDir} \
    --keep-directory-symlink \
    --numeric-owner 

rm --force \
   ${ayufanDir}/boot-saved.tar.xz

echo ""
echo "Adding /etc/fstab"
efiUUID=$(blkid /dev/${targetDev}${efiPart} -o export|grep '^UUID=')
rootUUID=$(blkid /dev/${targetDev}${rootPart} -o export|grep '^UUID=')
sed --expression="/\/boot /d" \
    --expression="s/\(UUID=\)\(.*\) \(\/\) \(.*\)/${rootUUID} \3 \4/" \
    --expression="s/\(UUID=\)\(.*\) \(\/boot\/efi\) \(.*\)/${efiUUID} \3 \4/" \
    --in-place ${rootfsDir}/etc/fstab

echo ""
echo "Setting default password"
sed --expression='s|!locked|$6$Pq9Td3SsXA/MOyYt$UiPhI4OPOW2WUeLzZVZj.IiZHuMgI4zRycKdCVapdSGHzpmTl6gyuLTDyPTJJ09nnq.EXc..z489j1GceVoqU1|' \
    --in-place ${rootfsDir}/etc/shadow

echo ""
echo "Removing initial-setup"
sysdDir=/etc/systemd/system
rm --force ${rootfsDir}${sysdDir}/graphical.target.wants/initial-setup.service
rm --force ${rootfsDir}${sysdDir}/multi-user.target.wants/initial-setup.service

cp finish-install.sh ${rootfsDir}/root/

echo ""
echo "Cleaning up"

sync
umount ${rootfsDir}
umount ${fedoraDir}
losetup -d ${loopDev}

echo ""
echo "Flashing complete!"
echo ""
echo "Please boot from the microSD card, login using root/fedora"
echo "  and run 'sh /root/finish-install.sh' to complete the installation"
echo ""
