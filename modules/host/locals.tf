locals {
  ssh_public_key = trimspace(file(var.public_key))
  # ssh_private_key is either the contents of var.private_key or null to use a ssh agent.
  ssh_private_key = var.private_key == null ? null : trimspace(file(var.private_key))
  # ssh_identity is not set if the private key is passed directly, but if ssh agent is used, the public key tells ssh agent which private key to use.
  # For terraforms provisioner.connection.agent_identity, we need the public key as a string.
  ssh_identity = var.private_key == null ? local.ssh_public_key : null
  # ssh_identity_file is used for ssh "-i" flag, its the private key if that is set, or a public key file
  # if an ssh agent is used.
  ssh_identity_file = var.private_key == null ? var.public_key : var.private_key
  # shared flags for ssh to ignore host keys, to use our ssh identity file for all connections during provisioning.
  ssh_args = "-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i ${local.ssh_identity_file}"

  microOS_install_commands = [
    "set -ex",
    "apt-get update",
    "apt-get install -y aria2",
    "aria2c --follow-metalink=mem https://download.opensuse.org/tumbleweed/appliances/openSUSE-MicroOS.x86_64-kvm-and-xen.qcow2.meta4",
    "qemu-img convert -p -f qcow2 -O host_device $(ls -a | grep -ie '^opensuse.*microos.*qcow2$') /dev/sda",
    "sgdisk -e /dev/sda",
    "parted -s /dev/sda resizepart 4 99%",
    "parted -s /dev/sda mkpart primary ext2 99% 100%",
    "partprobe /dev/sda && udevadm settle && fdisk -l /dev/sda",
    "mount /dev/sda4 /mnt/ && btrfs filesystem resize max /mnt && umount /mnt",
    "mke2fs -L ignition /dev/sda5",
    "mount /dev/sda5 /mnt",
    "mkdir /mnt/ignition",
    "cp /root/config.ign /mnt/ignition/config.ign",
    "mkdir /mnt/combustion",
    "cp /root/script /mnt/combustion/script",
    "umount /mnt"
  ]

  ignition_config = jsonencode({
    ignition = {
      version = "3.0.0"
    }
    passwd = {
      users = [{
        name              = "root"
        sshAuthorizedKeys = concat([local.ssh_public_key], var.additional_public_keys)
      }]
    }
    storage = {
      files = [
        {
          path      = "/etc/sysconfig/network/ifcfg-eth1"
          mode      = 420
          overwrite = true
          contents  = { "source" = "data:,BOOTPROTO%3D%27dhcp%27%0ASTARTMODE%3D%27auto%27" }
        },
        {
          path      = "/etc/ssh/sshd_config.d/kube-hetzner.conf"
          mode      = 420
          overwrite = true
          contents  = { "source" = "data:,PasswordAuthentication%20no%0AX11Forwarding%20no%0AMaxAuthTries%202%0AAllowTcpForwarding%20no%0AAllowAgentForwarding%20no%0AAuthorizedKeysFile%20.ssh%2Fauthorized_keys" }
        }
      ]
    }
  })

  combustion_script = <<EOF
#!/bin/bash
sed -i 's#NETCONFIG_NIS_SETDOMAINNAME="yes"#NETCONFIG_NIS_SETDOMAINNAME="no"#g' /etc/sysconfig/network/config
sed -i 's#WAIT_FOR_INTERFACES="30"#WAIT_FOR_INTERFACES="60"#g' /etc/sysconfig/network/config
sed -i 's#CHECK_DUPLICATE_IP="yes"#CHECK_DUPLICATE_IP="no"#g' /etc/sysconfig/network/config
# combustion: network
rpm --import https://rpm.rancher.io/public.key
zypper refresh
zypper --gpg-auto-import-keys install -y https://rpm.rancher.io/k3s/stable/common/microos/noarch/k3s-selinux-0.4-1.sle.noarch.rpm
udevadm settle || true
EOF

}
