#! /bin/bash

###' Global variables

LXCPATH=/srv/lxc

# Debian distribution 
DEBIAN_RELEASE=stretch
INSTALL_YUNOHOST_DIST='stable'

# Name of the master LXC container. Something like yunostretch or yunojessie
LXCMASTER_NAME=yuno${DEBIAN_RELEASE}
LXCMASTER_ROOTFS=${LXCPATH}/${LXCMASTER_NAME}/rootfs

# Log file
LOG_BUILD_LXC=/tmp/lxc-build.log

# Human-readable log of the build process
LOG=/tmp/yunobuild.log

LXC_BRIDGE="ynhbuildbr0"

# Name of the temporary container
CONT=${LXCMASTER_NAME}-$(date +%Y%m%d-%H%M)
CONT_ROOTFS=${LXCPATH}/${CONT}/rootfs

# APT command
APT='DEBIAN_FRONTEND=noninteractive apt install -y --assume-yes --no-install-recommends'

###.
###' Main function

function main() {
  set -x
  spawn_temp_lxc
  yunohost_install
  yunohost_post_install
  destroy_temp_lxc
}

###.
###' Create a master container

# Execute a command inside the container
function _lxc_exec() {
  LC_ALL=C LANGUAGE=C LANG=C lxc-attach -P ${LXCPATH} -n ${CONT} -- /bin/bash -c "$1"
}

function build_lxc_master_if_needed() {
  mkdir -p "${LXCPATH}"
  if ! lxc-ls -P ${LXCPATH} | grep "^${LXCMASTER_NAME}$"
  then
    # If btrfs is available, use it as a fast-cloning backend for LXC.
    fstype=$(df --output=fstype "${LXCPATH}" | tail -n 1)
    if [ "$fstype" != "btrfs" ]; then
      fstype="dir"
    fi
    sudo lxc-create -P $LXCPATH -B $fstype -n $LXCMASTER_NAME -t debian -- -r $DEBIAN_RELEASE
    sed -i "s/^lxc.network.type.*$/lxc.network.type = veth\nlxc.network.flags = up\nlxc.network.link = $LXC_BRIDGE\nlxc.network.name = eth0\nlxc.network.hwaddr = 00:FF:AA:BB:CC:01/" ${LXCPATH}/${LXCMASTER_NAME}/config

    # Configure debian apt repository
    cat <<EOT > $LXCMASTER_ROOTFS/etc/apt/sources.list
deb http://ftp.fr.debian.org/debian $DEBIAN_RELEASE main contrib non-free
deb http://security.debian.org/ $DEBIAN_RELEASE/updates main contrib non-free
EOT
    cat <<EOT > $LXCMASTER_ROOTFS/etc/apt/apt.conf.d/71-no-recommends
APT::Install-Suggests "0";
// We're too shy to disable recommends globally in yunohost
// because apps packagers probably rely on recommended packages
// being automatically installed.
//APT::Install-Recommends "0";
EOT

    if [ ${APTCACHER} ] ; then
      cat <<EOT > $LXCMASTER_ROOTFS/etc/apt/apt.conf.d/01proxy
Acquire::http::Proxy "http://${APTCACHER}:3142";
EOT
    fi

    sudo lxc-start -P $LXCPATH -n $LXCMASTER_NAME
    sleep 5
    LC_ALL=C LANGUAGE=C LANG=C sudo lxc-attach -P ${LXCPATH} -n ${LXCMASTER_NAME} -- apt-get update
#    echo set locales/locales_to_be_generated en_US.UTF-8 | debconf-communicate
#    echo set locales/default_environment_locale en_US.UTF-8 | debconf-communicate
    LC_ALL=C LANGUAGE=C LANG=C sudo lxc-attach -P ${LXCPATH} -n ${LXCMASTER_NAME} -- locale-gen en_US.UTF-8
    LC_ALL=C LANGUAGE=C LANG=C sudo lxc-attach -P ${LXCPATH} -n ${LXCMASTER_NAME} -- localedef -i en_US -f UTF-8 en_US.UTF-8
    DEBIAN_FRONTEND=noninteractive LC_ALL=C LANGUAGE=C LANG=C sudo lxc-attach -P ${LXCPATH} -n ${LXCMASTER_NAME} -- apt -y --assume-yes --no-install-recommends install \
    ca-certificates openssh-server ntp parted locales vim-nox bash-completion rng-tools wget \
    gnupg2 python3 curl 'php-fpm|php5-fpm'
    LC_ALL=C LANGUAGE=C LANG=C sudo lxc-attach -P ${LXCPATH} -n ${LXCMASTER_NAME} -- apt -y --purge autoremove
    LC_ALL=C LANGUAGE=C LANG=C sudo lxc-attach -P ${LXCPATH} -n ${LXCMASTER_NAME} -- apt -y clean
    sudo lxc-stop -P $LXCPATH -n $LXCMASTER_NAME
  fi
}

function spawn_temp_lxc() {
  build_lxc_master_if_needed
  sudo lxc-copy -P $LXCPATH -n $LXCMASTER_NAME -N $CONT
  sudo lxc-start -P $LXCPATH -n $CONT
  sleep 5 # Networking setup needs a few seconds
}

function destroy_temp_lxc() {
  sudo lxc-stop -P $LXCPATH -n $CONT
  sudo lxc-destroy -P $LXCPATH -n $CONT
}

###.
###' Yunohost install & post-install

function yunohost_install() {
  _lxc_exec "wget -O /tmp/install_yunohost https://install.yunohost.org/${DEBIAN_RELEASE} && chmod +x /tmp/install_yunohost"
  _lxc_exec "cd /tmp/ && ./install_yunohost -a -d ${INSTALL_YUNOHOST_DIST}"
}
function yunohost_post_install() {
  _lxc_exec "yunohost tools postinstall -d foo.bar.labriqueinter.net -p yunohost --ignore-dyndns --debug"
}

###.
###' Create ISO images

function _create_image_with_encrypted_fs() {
  BOARD="${1}"
  . ./build/config_board.sh
  echo $FLASH_KERNEL > ${CONT_ROOTFS}/etc/flash-kernel/machine
  _lxc_exec 'update-initramfs -u -k all'
  ./build/create_device.sh -D img -s 1500 \
   -t /srv/olinux/labriqueinternet_${FILE}_encryptedfs_"$(date '+%Y-%m-%d')"_${DEBIAN_RELEASE}${INSTALL_YUNOHOST_TESTING}.img \
   -d ${CONT_ROOTFS} \
   -b $BOARD

  pushd /srv/olinux/
  tar czf labriqueinternet_${FILE}_encryptedfs_"$(date '+%Y-%m-%d')"_${DEBIAN_RELEASE}${INSTALL_YUNOHOST_TESTING}.img{.tar.xz,}
  popd
}

function _create_standard_image() {
  # Switch to unencrypted root
  echo 'LINUX_KERNEL_CMDLINE="console=tty0 hdmi.audio=EDID:0 disp.screen0_output_mode=EDID:1280x720p60 root=/dev/mmcblk0p1 rootwait sunxi_ve_mem_reserve=0 sunxi_g2d_mem_reserve=0 sunxi_no_mali_mem_reserve sunxi_fb_mem_reserve=0 panic=10 loglevel=6 consoleblank=0"' >  ${CONT_ROOTFS}/etc/default/flash-kernel
  rm -f ${CONT_ROOTFS}/etc/crypttab
  echo '/dev/mmcblk0p1      /     ext4    defaults        0       1' > ${CONT_ROOTFS}/etc/fstab

  . ./build/config_board.sh
  echo $FLASH_KERNEL > ${CONT_ROOTFS}/etc/flash-kernel/machine
  _lxc_exec 'update-initramfs -u -k all'
  ./build/create_device.sh -D img -s 1500 \
   -t /srv/olinux/labriqueinternet_${FILE}_"$(date '+%Y-%m-%d')"_${DEBIAN_RELEASE}${INSTALL_YUNOHOST_TESTING}.img \
   -d ${CONT_ROOTFS} \
   -b $BOARD

  pushd /srv/olinux/
  tar czf labriqueinternet_${FILE}_"$(date '+%Y-%m-%d')"_${DEBIAN_RELEASE}${INSTALL_YUNOHOST_TESTING}.img{.tar.xz,}
  popd
}

function create_images() {
  if test "z${BUILD_ENCRYPTED_IMAGES}" = "zyes"
  then
  for BOARD in ${boardlist[@]}; do
    _create_image_with_encrypted_fs "$BOARD"
  done
  fi
}

###.

# Launch the build process
main

# vim: foldmethod=marker foldmarker=###',###.