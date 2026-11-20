// dpu_common_pcie.f（dpu_common 可选 add-on）的 package import：在使用它的 package 或 module 内部写一行 `include "dpu_common_pcie_import.svh"。
// 只列 dpu_common_pcie.f 编译的 package；dpu_common 主体与依赖项目的 import 由各自的 *_import.svh 提供。
// 故意不加 include guard：每个需要的 package/module 各 include 一次。
import dpu_pcie_pkg::*;
