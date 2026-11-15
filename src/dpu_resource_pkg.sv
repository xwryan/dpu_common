// dpu_resource_pkg 编译入口：按依赖顺序包含资源类型、配置、快照、解析器与管理器。

`ifndef DPU_RESOURCE_PKG_SV
`define DPU_RESOURCE_PKG_SV

package dpu_resource_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  // aip_core 须先编译；只导入不 include，避免同一类型在多个 package 中重复定义。
  import aip_core_pkg::*;

  `include "dpu_device_types.sv"
  `include "dpu_placement_types.sv"
  `include "dpu_resource_types.sv"
  `include "dpu_placement_cfg.sv"
  `include "dpu_dut_caps.sv"
  `include "dpu_device_cfg.sv"
  `include "dpu_normalized_placement_plan.sv"
  `include "dpu_placement_normalizer.sv"
  `include "dpu_device_snapshot.sv"
  `include "dpu_device_resolver.sv"
  `include "dpu_resource_snapshot.sv"
  `include "dpu_resource_resolver.sv"
  `include "dpu_configuration_resolver.sv"
  `include "dpu_resource_manager.sv"
  `include "dpu_bar_map.sv"
  `include "dpu_table_types.sv"
  `include "dpu_vio_table_types.sv"
  `include "dpu_env_cfg.sv"
  `include "dpu_device_env.sv"
  `include "dpu_names.sv"
endpackage : dpu_resource_pkg

`endif // DPU_RESOURCE_PKG_SV
