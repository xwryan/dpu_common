// dpu_common 主 filelist：用大写 -F 引用（vcs -F <路径>/dpu_common/dpu_common.f），文件与 +incdir+ 都相对本文件目录，可在任意目录编译。
// 不拉入依赖：前置项目每个写一行 -F，依次为 aip_core/aip_core.f。
// 只编译根入口 dpu_common_pkg.sv；在自己的 package/module 内 `include "dpu_common_import.svh" 即可 import 本项目的 package。
// PCIe TL 配置包在 add-on dpu_common_pcie.f（需 pcie_work，不能并入本文件）。
+incdir+./
+incdir+./src
./dpu_common_pkg.sv
