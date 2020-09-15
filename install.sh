#!/bin/bash

# Default value used if no arguments are provided
targetDev=sdb
fedoraImage=Fedora-Minimal-32-1.6.aarch64.raw
debianImage=buster-minimal-rockpro64-0.10.12-1184-arm64.img
rootSize=9500
efiPart=2
bootPart=3
rootPart=4
noquestions=false

bootfsDir=${PWD}/bootfs
rootfsDir=${PWD}/rootfs
fedoraDir=${PWD}/fedora
ayufanDir=${PWD}/ayufan

if   ! test -d ${bootfsDir} \
  || ! test -d ${rootfsDir} \
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
  echo "            [--root-size=<RootPartSizeInMiB>]"
  echo "            [-y]"
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
        bootPart="p${bootPart}"
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
      if ! [[ ${rootSize} =~ ^[0-9]+$ ]]
      then
        echo "--root-size option can be numeric only! - Aborting"
        exit 1
      fi
    ;;
    --yes|-y)
      noQuestions=true
    ;;
    *)
      usage
      exit 1
    ;;
  esac
  shift
done

cat banner.txt

if ! ${noQuestions}
then
  echo "WARNING: Proceeding will result in the loss of ALL data on device /dev/${targetDev} !! "
  read -p "Are you sure you want to proceed [y,N]? " -r
  echo 
  if [[ ! ${REPLY} =~ ^[yY]$ ]] 
  then
    echo "Leaving flash process before any harm was done"
    usage
    exit 0
  fi
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

dd if=${debianImage} \
   of=/dev/${targetDev} \
   bs=1MB \
   oflag=direct \
   status=progress
sync
partprobe --summary /dev/${targetDev}
sync
sgdisk --move-second-header /dev/${targetDev}
sync

rootPartStart=$(parted -m /dev/${targetDev} unit MiB print | \
                grep "^${rootPart}:" | \
                awk -F: '{print $2}' | \
                sed 's/MiB//')
rootPartSize=$(parted -m /dev/${targetDev} unit MiB print | \
               grep "^${rootPart}:" | \
               awk -F: '{print $3}' | \
               sed 's/MiB//')

if [[ ${rootSize} -gt ${rootPartSize} ]]
then
  rootPartEnd=$((${rootPartStart} + ${rootSize}))
  echo ""
  echo "Resize root partition (${rootPart}) to ${rootSize}MiB"
  echo "resizepart ${rootPart} ${rootPartEnd}MiB\n\q\n" | \
       parted /dev/${targetDev}
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
fi

echo ""
echo "Mounting $(basename ${bootfsDir}) filesystem"
mount /dev/${targetDev}${bootPart} ${bootfsDir}
rm --force \
   ${bootfsDir}/filesystem.packages*

echo ""
echo "Mounting $(basename ${rootfsDir}) filesystem"
mount /dev/${targetDev}${rootPart} ${rootfsDir}

echo "Saving Ayufan rootfs Kernel artifacts"
tar --create \
    --acls \
    --checkpoint=100 \
    --checkpoint-action=dot \
    --xattrs \
    --xz \
    --file=${ayufanDir}/kernel-saved.tar.xz \
    --directory=${rootfsDir} \
    etc/firmware \
    lib/firmware \
    lib/modules

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
    --exclude=boot/* \
    --exclude=tmp/* \
    --exclude=etc/firmware \
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
echo "Adding rootfs Kernel artifacts from Ayufan"
tar --extract \
    --acls \
    --checkpoint=100 \
    --checkpoint-action=dot \
    --same-permissions \
    --same-owner \
    --same-order \
    --xattrs \
    --xz \
    --file=${ayufanDir}/kernel-saved.tar.xz \
    --directory=${rootfsDir} \
    --keep-directory-symlink \
    --numeric-owner 

rm --force \
   ${ayufanDir}/kernel-saved.tar.xz

echo ""
echo "Adding /etc/fstab"
efiUUID=$(blkid /dev/${targetDev}${efiPart} -o export|grep '^UUID=')
bootUUID=$(blkid /dev/${targetDev}${bootPart} -o export|grep '^UUID=')
rootUUID=$(blkid /dev/${targetDev}${rootPart} -o export|grep '^UUID=')
sed --expression="s/\(UUID=\)\(.*\) \(\/boot\) \(.*\)/${bootUUID} \3 \4/" \
    --expression="s/\(UUID=\)\(.*\) \(\/\) \(.*\)/${rootUUID} \3 \4/" \
    --expression="s/\(UUID=\)\(.*\) \(\/boot\/efi\) \(.*\)/${efiUUID} \3 \4/" \
    --in-place ${rootfsDir}/etc/fstab

echo ""
echo "Updating kernel options"
sed --expression="s#init=/sbin/init#systemd.unified_cgroup_hierarchy=0#" \
    --expression="s#root=LABEL=linux-root#root=${rootUUID} quiet#" \
    --expression="s#panic=10#loglevel=4 panic=10#" \
    --in-place ${bootfsDir}/extlinux/extlinux.conf

echo ""
echo "Setting default root password to 'fedora'"

rootEntry=$(grep '^root:' ${rootfsDir}/etc/shadow \
            | awk -F':' \
                  -v pass='$6$Pq9Td3SsXA/MOyYt$UiPhI4OPOW2WUeLzZVZj.IiZHuMgI4zRycKdCVapdSGHzpmTl6gyuLTDyPTJJ09nnq.EXc..z489j1GceVoqU1' \
                  '{print $1":"pass":"$3":"$4":"$5":"$6":"$7":"$8":"$9}')
sed --expression="s|^root:.*$|${rootEntry}|" \
    --in-place \
    ${rootfsDir}/etc/shadow

echo ""
echo "Removing initial-setup"
sysdDir=/etc/systemd/system
rm --force ${rootfsDir}${sysdDir}/graphical.target.wants/initial-setup.service
rm --force ${rootfsDir}${sysdDir}/multi-user.target.wants/initial-setup.service

echo ""
echo "Removing audit service (Ayufan does not include it in the kernel)"
rm --force ${rootfsDir}${sysdDir}/graphical.target.wants/auditd.service
rm --force ${rootfsDir}${sysdDir}/multi-user.target.wants/auditd.service

cp finish-install.sh ${rootfsDir}/root/

echo ""
echo "Cleaning up"

sync

umount ${bootfsDir}
umount ${rootfsDir}
umount ${fedoraDir}
losetup -d ${loopDev}

echo ""
echo "Flashing complete!"
echo ""
echo "Please boot from the microSD card, login using root/fedora"
echo "  and run 'sh /root/finish-install.sh' to complete the installation"
echo ""
