// dpu_common 根入口：dpu_common.f 唯一编译的源文件，按原编译顺序 include 本项目的全部源码（package、interface、module）；
// 路径相对仓库根目录，经 dpu_common.f 的 +incdir+./ 解析。依赖项目须先经各自的 filelist 编译。
`ifndef DPU_COMMON_PKG_SV
`define DPU_COMMON_PKG_SV
`include "src/dpu_resource_pkg.sv"
`endif // DPU_COMMON_PKG_SV
