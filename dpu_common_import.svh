// dpu_common 的 package import：在使用本项目的 package 或 module 内部写一行 `include "dpu_common_import.svh"（dpu_common.f 的 +incdir+./ 提供路径）。
// 只列本项目 dpu_common.f 编译的 package；依赖项目的 import 由它们各自的 *_import.svh 提供。
// 故意不加 include guard：每个需要的 package/module 各 include 一次。
import dpu_resource_pkg::*;
