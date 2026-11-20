// dpu_common 可选 add-on：PCIe TL 配置包 dpu_pcie_pkg（BAR map、dpu_cfg_seq、dpu_bar_reg_seq）。
// 它需要 pcie_work，而 pcie_work.f 需要 dpu_common，所以不能并入 dpu_common.f；virtio_work、dpu_queue_work、rdma_work 都需要它。
// 用大写 -F 引用（vcs -F <路径>/dpu_common/dpu_common_pcie.f），路径相对本文件目录；不拉入依赖，前置每个写一行 -F，依次为 aip_core/aip_core.f host_mem/host_mem.f dpu_common/dpu_common.f pcie_work/pcie_work.f。
// 在自己的 package/module 内 `include "dpu_common_pcie_import.svh" 即可 import 本 add-on 的 package。
+incdir+./integration/pcie
./integration/pcie/dpu_pcie_pkg.sv
