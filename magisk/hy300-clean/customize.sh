# Stubs keep the originals' ownership (root:shell) and mode.
for s in qw appsdisable gmsopt preinstall runin.sh product_update_oem.sh; do set_perm "$MODPATH/system/bin/$s" 0 2000 0755; done
set_perm "$MODPATH/remote-buttons.sh" 0 0 0755
[ -f "$MODPATH/system/product/overlay/NetworkStackConfigHy300.apk" ] && set_perm "$MODPATH/system/product/overlay/NetworkStackConfigHy300.apk" 0 0 0644
