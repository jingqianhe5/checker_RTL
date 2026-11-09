# Regression and evidence runs use the same detailed three-checksum signal set.
# The caller supplies output paths for its FIFO depth/snapshot.
if {![info exists wave_file]} {set wave_file system.vcd}
if {![info exists wave_config_file]} {set wave_config_file system.wcfg}
source [file join [file dirname [info script]] waves_evidence.tcl]
