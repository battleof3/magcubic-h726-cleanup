#!/system/bin/sh
# Stock firmware boots permissive (androidboot.selinux=permissive in cmdline and bootconfig).
# sepolicy.rule fills the vendor's policy gaps; switch to enforcing here, before HALs,
# system_server and apps start.
setenforce 1
