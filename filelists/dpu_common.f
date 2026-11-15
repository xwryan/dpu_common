// dpu_common standalone package filelist.
//
// DPU_COMMON_ROOT is the repository root.  The package itself includes the
// implementation units in dependency order.  aip_core must be compiled first,
// exactly once (filelists/aip_core.f when standalone).  No PCIe/TL/SVT or
// host-memory implementation is imported.
+incdir+$DPU_COMMON_ROOT/src
$DPU_COMMON_ROOT/src/dpu_resource_pkg.sv
