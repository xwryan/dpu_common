// 公共 DUT 表配置 sequence：只依赖 dpu_env_cfg 与原生 PCIe TL，所有访问经 pcie_tl_reg_seq 发往实际目标 RC；ring/BAR 不归 seq 所有。
// 默认 body：Host0/PF0 声明为 AF 并读回状态 8，再配置 BDF、VIO/QSCH（MSI-X 按完成模式）；每批 Notify 成功后每个管理 BAR 写一次
// ready=1（bank0）：VIO +0x80044，RDMA +0x80048。
// Notify 只写实际队列对的有效项；未用槽位保持 DUT 复位值（05.png：type=3，lookup key/global_qid 全 1，reserved=0），seq 不写不读。
// 配置最后对每条仍有未冲刷写的 RC 读一次（flush_writes），读完成即说明此前的 posted 写都已到 DUT。
class dpu_cfg_seq extends uvm_sequence #(pcie_tl_tlp);
	`uvm_object_utils(dpu_cfg_seq)

	dpu_env_cfg		cfg;
	dpu_cfg_scope	selection;
	bit				success;
	string			error_msg;
	// 当前 seq 自上次成功 AF 状态读之后完成的完整 DWORD 写数；每次 start 独立计数。
	protected int unsigned	writes_since_af_read;
	// 按 RC sequencer 记录其上最后一笔之后还没有读的写；同 RC 的任一读完成即冲刷，删除记录。
	protected dpu_bar_target_t	unflushed_target[string];
	protected logic [63:0]		unflushed_offset[string];

	extern function new(string	name = "dpu_cfg_seq");

	// UVM 即使 start(..., call_pre_post=0) 也调用 pre_start，故在此取 cfg，派生 body 可直接使用。
	extern virtual task pre_start();

	// 平台先等待复位就绪；AF 声明先于写表，VIO 在写入、所选验证和 commit 后成功。
	extern virtual task body();

	// 向 Host0/PF0 BAR0+0x1010 写声明后同步读一次状态，须为 8；不受 configure_public/verify_readback 控制，不轮询，任一步失败停止。
	extern virtual task declare_af(
		output bit		ok,
		output string	why
	);

	// 同步读一次 AF 状态并要求为 8（首次声明及每 100 笔完整 DWORD 写各一次，Completion 返回前不得继续写）；成功清写计数，不轮询。
	extern protected task read_af_status(
		output bit		ok,
		output string	why
	);

	// 读不越过此前的 posted 写：每条有未冲刷写的 RC 读一次，管理 RC 读 AF 状态（须为 8），其他 RC 回读该 RC
	// 最后写的 DWORD（不比对数据）；body 收尾调用，直接调用独立 configure_* 入口的 seq 也可自行调用。
	extern task flush_writes(
		output bit		ok,
		output string	why
	);

	// start 返回前报告失败，AIP 直接注册本类时也不会把提前 return 显示为配置成功。
	extern virtual task post_start();

	// 给当前失败添加阶段名；所有调用均在首次失败停止，不继续使能或释放资源。
	extern protected function bit completed_step(
		input string	step,
		input bit		ok
	);

	// offset 相对所选 Function 的真实 BAR（失败不回退默认窗口）；校验四态输入与完整范围，posted 成功仅表示已发送。
	extern task pcie_bar_write(
		input dpu_function_key_t	owner,
		input int unsigned			bar_id,
		input logic [63:0]			offset,
		input int unsigned			length,
		input logic [127:0]			data,
		input logic [31:0]			byte_skip_mask,
		output bit					ok,
		output string				why
	);

	// 读 Completion 的失败和短数据由底层 sequence 明确上传，不把默认零当成功。
	extern task pcie_bar_read(
		input dpu_function_key_t	owner,
		input int unsigned			bar_id,
		input logic [63:0]			offset,
		input int unsigned			length,
		input logic [31:0]			byte_skip_mask,
		output logic [127:0]		data,
		output bit					ok,
		output string				why
	);

	// 手动路径无隐含 Host，多个 Host 时必须写完整 h 前缀。
	extern task pcie_bar_write_by_name(
		input string		name,
		input logic [63:0]	offset,
		input int unsigned	length,
		input logic [127:0]	data,
		input logic [31:0]	byte_skip_mask,
		output bit			ok,
		output string		why
	);

	// 名字解析与实际 Function API 复用同一个范围/格式检查。
	extern task pcie_bar_read_by_name(
		input string			name,
		input logic [63:0]		offset,
		input int unsigned		length,
		input logic [31:0]		byte_skip_mask,
		output logic [127:0]	data,
		output bit				ok,
		output string			why
	);

	// 用户自定义表按高 DWORD 到低 DWORD 写；完整预检后发送，失败立即停止。
	// 不隐含控制触发或读回；在配置 sequence 内按所需顺序调用。
	extern task pcie_table_write_by_name(
		input string		name,
		input logic [63:0]	offset,
		input int unsigned	length,
		input logic [127:0]	data,
		output bit			ok,
		output string		why
	);

	// 有界显式轮询；比较 mask 与 byte skip-mask 是不同概念，不在后台自动读状态。
	extern task pcie_poll_bar(
		input dpu_function_key_t	owner,
		input int unsigned			bar_id,
		input logic [63:0]			offset,
		input int unsigned			length,
		input logic [127:0]			mask,
		input logic [127:0]			expected,
		input int unsigned			attempts,
		input time					interval,
		output bit					ok,
		output string				why
	);

	// 首笔发送前校验完整表项绑定与字段宽度，再由高到低顺序发送全部 DWORD（enabling 只改声明的 enable/mask 位）；
	// VTX/VRX 四笔数据全部成功后才发 clear/trigger，期间不插入其他表访问。
	extern protected task checked_write(
		input dpu_table_item_t	record,
		input logic [127:0]		value,
		input bit				enabling,
		output bit				ok,
		output string			why
	);

	// 四态检查在转换为两态 registry/sequence 前完成（保留小端 byte lane 与 skip-mask 语义）；check_read_data 仅为状态读关闭 SCB 的 RAM 写值比较。
	extern protected task mmio(
		input dpu_bar_target_t	target,
		input bit				writing,
		input logic [63:0]		offset,
		input int unsigned		length,
		input logic [127:0]		data,
		input logic [31:0]		byte_skip_mask,
		output logic [127:0]	result,
		output bit				ok,
		output string			why,
		input bit				check_read_data = 1
	);

	// 统一表项写序：≤128 bit 表项每次发 32 bit，高位 DWORD 放高地址、DWORD 内字节不反转；
	// 首笔前检查整项宽度、已知值、BAR 与 4KB 范围，禁止先发送再发现越界。
	extern protected task write_table_dwords(
		input dpu_bar_target_t	target,
		input logic [63:0]		offset,
		input int unsigned		length,
		input logic [127:0]		data,
		output bit				ok,
		output string			why
	);

	// 公共控制 hook 可复用同一 checked 路径；mask 和消费者也必须匹配原件。
	extern virtual task write_control(
		input dpu_control_cfg_t	item,
		output bit				ok,
		output string			why
	);

	// 辅助项有实际 ring 绑定，不能借控制 payload 修改另一个 pair。
	extern virtual task write_queue_aux(
		input dpu_queue_control_cfg_t	item,
		output bit						ok,
		output string					why
	);

	// 唯一 typed dispatch；不在单项 hook 中复制外围循环，也不隐含执行其他类别。
	extern protected task dispatch_record(
		input dpu_table_item_t	record,
		output bit				ok,
		output string			why
	);

	// 先生成所选公共表，再逐项调用用户 hook；同一硬件项只写一次，失败立即停止。
	extern protected task configure_public(
		input dpu_table_kind_e	kinds[$],
		input dpu_cfg_scope		scope,
		output bit				ok,
		output string			why
	);

	// 按实际 service/qpair 遍历；共享 QSCH 项去重，TX-only 不生成 VRX 写入。
	extern protected task configure_queues(
		input dpu_table_kind_e	kinds[$],
		input dpu_cfg_scope		selection,
		output bit				ok,
		output string			why
	);

	// 完整预检后逐项写入；只在本批表项全部成功后使能 Notify，不保存跨调用状态。
	extern protected task write_records(
		input dpu_table_item_t	batch[$],
		output bit				ok,
		output string			why
	);

	// Notify ready 寄存器（驱动 INTF_PCMPL_CFG_{VIO,RDMA}_NOTIFY_TAB）：VIO 0x80044，RDMA 0x80048；完整 BAR 内偏移。
	extern static function bit [63:0] notify_ready_offset(input dpu_table_kind_e	kind);

	// 使能已完成写表的管理窗口：按表类型写 ready=1、sel=0（bank0），不叠加表地址。
	extern virtual task enable_notify(
		input dpu_bar_target_t	target,
		input dpu_table_kind_e	kind,
		output bit				ok,
		output string			why
	);

	// 以下独立 configure_* 入口：完整预检本 scope 后才调用对应单项 hook，不隐含调用其他类别。
	extern task configure_bar_table(
		input dpu_cfg_scope	scope,
		output bit			ok,
		output string		why
	);

	extern task configure_af(
		input dpu_cfg_scope	scope,
		output bit			ok,
		output string		why
	);

	extern task configure_pf_vf_map(
		input dpu_cfg_scope	scope,
		output bit			ok,
		output string		why
	);

	extern task configure_bdf_table(
		input dpu_cfg_scope	scope,
		output bit			ok,
		output string		why
	);

	extern task configure_completion_bdf_table(
		input dpu_cfg_scope	scope,
		output bit			ok,
		output string		why
	);

	extern task configure_tlp_prefix(
		input dpu_cfg_scope	scope,
		output bit			ok,
		output string		why
	);

	extern task configure_msix(
		input dpu_cfg_scope	scope,
		output bit			ok,
		output string		why
	);

	extern task enable_msix(
		input dpu_cfg_scope	scope,
		output bit			ok,
		output string		why
	);

	extern task configure_rdma_notify(
		input dpu_cfg_scope	scope,
		output bit			ok,
		output string		why
	);

	extern task configure_qsch_rnet(
		input dpu_cfg_scope	scope,
		output bit			ok,
		output string		why
	);

	// 每对队列只写一条排序后的有效 Notify 项（TX/RX 已由 cfg 去重）；不初始化或读回未用槽位。
	extern task configure_vio_notify(
		input dpu_cfg_scope	selection,
		output bit			ok,
		output string		why
	);

	// MSI-X linear 按查找键排列；完整流程把单 bank 尾部填为无效行（非 reserved 字段全 1，排在目录末尾），
	// 只用统一管理窗口的单 bank，不切换 bank、不写 ready 寄存器；独立表入口不隐含初始化。
	extern protected task process_msix_tail(
		input bit		verify,
		output bit		ok,
		output string	why
	);

	extern task configure_qsch(
		input dpu_cfg_scope	selection,
		output bit			ok,
		output string		why
	);

	// 每个实际管理 BAR 写一次 QSCH 模式，按开关读回；不改变调度表的 owner 或索引。
	extern task configure_qsch_mode(
		input dpu_cfg_scope	selection,
		output bit			ok,
		output string		why
	);

	extern task configure_vio_queues(
		input dpu_cfg_scope	selection,
		output bit			ok,
		output string		why
	);

	// 使能和验证分别执行；任何必需类别失败均保留 DMA 并阻止提交。
	extern task enable_vio_queues(
		input dpu_cfg_scope	selection,
		output bit			ok,
		output string		why
	);

	// 公共配置写完后交由平台读回或检查状态；不将 posted 发送完成当成硬件生效。
	extern task verify_dpu_configuration(
		input dpu_cfg_scope	scope,
		output bit			ok,
		output string		why
	);

	// 读回本轮 BDF 与所选 MSI-X 数据表（空 scope 表示该类别未执行，不会意外验证全部 Function）；
	// 默认 body 仅在 verify_readback=1 时调用，显式调用总是真实读取。
	extern virtual task verify_function_configuration(
		input dpu_cfg_scope	bdf_scope,
		input dpu_cfg_scope	msix_scope,
		output bit			ok,
		output string		why
	);

	// 队列配置写完后执行平台验证；成功后默认 body 才调用 commit_queues。
	extern task verify_vio_configuration(
		input dpu_cfg_scope	selection,
		output bit			ok,
		output string		why
	);

	// 以下 typed 写入口在发送前核对 ctx/binding/entry 与本代原件，不接受任意 raw 表项；均复用唯一的逐 DWORD 写实现。
	extern virtual task write_bdf(
		input dpu_bdf_cfg_t	item,
		output bit			ok,
		output string		why
	);

	extern virtual task write_completion_bdf(
		input dpu_completion_bdf_cfg_t	item,
		output bit						ok,
		output string					why
	);

	extern virtual task write_pfvf(
		input dpu_pfvf_cfg_t	item,
		output bit				ok,
		output string			why
	);

	extern virtual task write_tlp_prefix(
		input dpu_tlp_prefix_cfg_t	item,
		output bit					ok,
		output string				why
	);

	extern virtual task write_msix_linear(
		input dpu_msix_linear_cfg_t	item,
		output bit					ok,
		output string				why
	);

	extern virtual task write_msix_info(
		input dpu_msix_info_cfg_t	item,
		output bit					ok,
		output string				why
	);

	extern virtual task write_msix_interval(
		input dpu_msix_interval_cfg_t	item,
		output bit						ok,
		output string					why
	);

	extern virtual task write_msix_table(
		input dpu_msix_table_cfg_t	item,
		output bit					ok,
		output string				why
	);

	extern virtual task write_qsch_q2tc(
		input dpu_qsch_q2tc_cfg_t	item,
		output bit					ok,
		output string				why
	);

	extern virtual task write_qsch_n2g(
		input dpu_qsch_n2g_cfg_t	item,
		output bit					ok,
		output string				why
	);

	extern virtual task write_qsch_g2p(
		input dpu_qsch_g2p_cfg_t	item,
		output bit					ok,
		output string				why
	);

	extern virtual task write_rdma_notify(
		input dpu_rdma_notify_cfg_t	item,
		output bit					ok,
		output string				why
	);

	extern virtual task write_qsch_rnet(
		input dpu_qsch_rnet_cfg_t	item,
		output bit					ok,
		output string				why
	);

	extern virtual task write_vtx(
		input dpu_vtx_cfg_t	item,
		output bit			ok,
		output string		why
	);

	extern virtual task write_vrx(
		input dpu_vrx_cfg_t	item,
		output bit			ok,
		output string		why
	);

	extern virtual task write_vio_notify(
		input dpu_vio_notify_cfg_t	item,
		output bit					ok,
		output string				why
	);

	// 以下 user_* hook 为平台专有控制，须由用户实现：默认不报告成功，也不自动调用旧 reset/init。
	extern virtual task user_prepare_device(
		input dpu_control_cfg_t	item,
		output bit				ok,
		output string			why
	);

	extern virtual task user_configure_af(
		input dpu_control_cfg_t	item,
		output bit				ok,
		output string			why
	);

	extern virtual task user_configure_msix_control_entry(
		input dpu_control_cfg_t	item,
		output bit				ok,
		output string			why
	);

	extern virtual task user_configure_msix_function(
		input dpu_control_cfg_t	item,
		output bit				ok,
		output string			why
	);

	extern virtual task user_quiesce_device(
		input dpu_control_cfg_t	item,
		output bit				ok,
		output string			why
	);

	extern virtual task user_reset_device(
		input dpu_control_cfg_t	item,
		output bit				ok,
		output string			why
	);

	// BAR 映射必须接收完整原子组，不能推测连续 VF 窗口。
	extern virtual task user_configure_bar_mapping_entry(
		input dpu_bar_mapping_cfg_t	item,
		output bit					ok,
		output string				why
	);

	// 独立于写入入口验证平台已有配置；默认失败，成功只确认传入 scope。
	extern virtual task user_verify_dpu_configuration(
		input dpu_cfg_scope	scope,
		output bit			ok,
		output string		why
	);

	// 默认读回实际配置表（而非共享 staging 端口）并比较，已使能队列按 enable 位更新期望值，任一不符阻止 commit；
	// 自清零或只写寄存器的项目可覆写此验证。
	extern virtual task user_verify_vio_configuration(
		input dpu_cfg_scope	selection,
		output bit			ok,
		output string		why
	);

	// 使能专用 checked 入口，只允许冻结 enable 位变化并完整核对 ring 绑定。
	extern virtual task write_enabled_queue(
		input dpu_queue_control_cfg_t	item,
		output bit						ok,
		output string					why
	);

	// PBA 为只读：读整个 64 位值，容量不从结构体宽度推断；只读查询与 W1C 清除相互独立。
	extern task read_msix_pba(
		input dpu_state_query_t		item,
		output dpu_msix_pba_word_t	value,
		output bit					ok,
		output string				why
	);

	// 状态读取前核对冻结上下文，不允许把初始化表伪装成只读状态。
	extern task read_msix_stat(
		input dpu_state_query_t	item,
		output dpu_msix_stat_t	value,
		output bit				ok,
		output string			why
	);

	extern task read_pfvf_drop_status(
		input dpu_state_query_t			item,
		output dpu_pfvf_drop_status_t	value,
		output bit						ok,
		output string					why
	);

	// 显式 clear_mask 与状态值类型隔离；未知态、错误目标在用户 hook 前拒绝。
	extern task clear_pfvf_drop_status(
		input dpu_pfvf_drop_clear_cfg_t	item,
		output bit						ok,
		output string					why
	);

	// 平台按寄存器语义覆写以下状态读取 hook；未实现时不得返回伪造状态。
	extern virtual task user_read_msix_stat(
		input dpu_state_query_t	item,
		output dpu_msix_stat_t	value,
		output bit				ok,
		output string			why
	);

	extern virtual task user_read_pfvf_drop_status(
		input dpu_state_query_t			item,
		output dpu_pfvf_drop_status_t	value,
		output bit						ok,
		output string					why
	);

	// 清除由用户显式执行；不把读出的 status 自动回写。
	extern virtual task user_clear_pfvf_drop_status(
		input dpu_pfvf_drop_clear_cfg_t	item,
		output bit						ok,
		output string					why
	);

	// 公共配置不依赖 VIO；派生类在此准备真实 ring 并填 selection，失败保留现场。
	extern virtual task prepare_queues(
		output bit		ok,
		output string	why
	);
	// 成功写表/使能/验证后确认消费者；公共基类没有 ring 生命周期。
	extern virtual function void commit_queues(
		output bit		ok,
		output string	why
	);
	// 每次访问查询同一个可选 PCIe BAR 扩展，支持直接调用独立配置入口。
	extern protected function bit get_rc(
		input dpu_bar_target_t				target,
		output uvm_sequencer#(pcie_tl_tlp)	sequencer,
		output string						why
	);
endclass

function dpu_cfg_seq::new(string	name);
	super.new(name);
endfunction

task dpu_cfg_seq::pre_start();
	success              = 0;
	error_msg            = "";
	writes_since_af_read = 0;
	unflushed_target.delete();
	unflushed_offset.delete();
	if (m_sequencer == null) begin
		`uvm_fatal("PROJECT_CONFIG_SEQ", "start configuration on the project's PCIe RC sequencer")
	end
	if (!uvm_config_db#(dpu_env_cfg)::get(m_sequencer, "", "dpu_cfg", cfg) || cfg == null) begin
		`uvm_fatal("PROJECT_CONFIG_SEQ", "PCIe sequencer has no dpu_cfg")
	end
	if (!cfg.runtime_ready) begin
		`uvm_fatal("PROJECT_CONFIG_SEQ", "env connect must finish before configuration")
	end
endtask

task dpu_cfg_seq::body();
	dpu_cfg_scope		public_scope;
	dpu_cfg_scope		bdf_scope;
	dpu_cfg_scope		msix_scope;
	dpu_function_key_t	functions[$];
	int unsigned		bars[$];
	bit					ok;

	`uvm_info("PROJECT_CONFIG_SEQ", $sformatf("begin DUT configuration (readback=%0b)",
											  cfg.verify_readback), UVM_LOW)
	public_scope = new("public_scope", cfg.device_snapshot, functions, bars);
	if (cfg.configure_bdf) bdf_scope = public_scope;
	ok = cfg.select_msix_scope(msix_scope, error_msg);
	if (!completed_step("select_msix_scope", ok)) return;

	declare_af(ok, error_msg);
	if (!completed_step("declare_af", ok)) return;

	if (cfg.configure_public) begin
		configure_bar_table(public_scope, ok, error_msg);
		if (!completed_step("configure_bar_table", ok)) return;

		if (cfg.frozen_layouts.exists(DPU_TABLE_AF)) begin
			configure_af(public_scope, ok, error_msg);
			if (!completed_step("configure_af", ok)) return;
		end

		configure_pf_vf_map(public_scope, ok, error_msg);
		if (!completed_step("configure_pf_vf_map", ok)) return;

		configure_completion_bdf_table(public_scope, ok, error_msg);
		if (!completed_step("configure_completion_bdf_table", ok)) return;

		configure_tlp_prefix(public_scope, ok, error_msg);
		if (!completed_step("configure_tlp_prefix", ok)) return;
	end

	if (bdf_scope != null) begin
		configure_bdf_table(bdf_scope, ok, error_msg);
		if (!completed_step("configure_bdf_table", ok)) return;
	end

	// 消息映射与中断控制先于队列使能；无公共消息需求的 polling 不产生 MSI-X 配置写。
	if (msix_scope != null) begin
		configure_msix(msix_scope, ok, error_msg);
		if (!completed_step("configure_msix", ok)) return;

		process_msix_tail(0, ok, error_msg);
		if (!completed_step("initialize_msix_tail", ok)) return;

		enable_msix(msix_scope, ok, error_msg);
		if (!completed_step("enable_msix", ok)) return;
	end

	if (cfg.verify_readback) begin
		verify_function_configuration(bdf_scope, msix_scope, ok, error_msg);
		if (!completed_step("verify_function_configuration", ok)) return;

		if (msix_scope != null) begin
			process_msix_tail(1, ok, error_msg);
			if (!completed_step("verify_msix_tail", ok)) return;
		end

		if (cfg.configure_public) begin
			verify_dpu_configuration(public_scope, ok, error_msg);
			if (!completed_step("verify_dpu_configuration", ok)) return;
		end
	end

	prepare_queues(ok, error_msg);
	if (!completed_step("prepare_vio_configuration", ok)) return;

	if (selection != null) begin
		configure_vio_notify(selection, ok, error_msg);
		if (!completed_step("configure_vio_notify", ok)) return;

		configure_qsch(selection, ok, error_msg);
		if (!completed_step("configure_qsch", ok)) return;

		configure_vio_queues(selection, ok, error_msg);
		if (!completed_step("configure_vio_queues", ok)) return;

		enable_vio_queues(selection, ok, error_msg);
		if (!completed_step("enable_vio_queues", ok)) return;

		if (cfg.verify_readback) begin
			verify_vio_configuration(selection, ok, error_msg);
			if (!completed_step("verify_vio_configuration", ok)) return;
		end

		commit_queues(ok, error_msg);
		if (!completed_step("commit_vio_configuration", ok)) return;
	end

	flush_writes(ok, error_msg);
	if (!completed_step("flush_writes", ok)) return;

	success   = 1;
	error_msg = "";
	`uvm_info("PROJECT_CONFIG_SEQ", $sformatf("DUT configuration completed (readback=%0b)",
											  cfg.verify_readback), UVM_LOW)
endtask

task dpu_cfg_seq::declare_af(
	output bit		ok,
	output string	why
);
	pcie_bar_write_by_name("h0.pf0.bar0", 64'h1010, 4, 128'h5555_aaaa, 32'h0, ok, why);
	if (!ok) return;
	read_af_status(ok, why);
endtask

task dpu_cfg_seq::read_af_status(
	output bit		ok,
	output string	why
);
	dpu_bar_target_t	target;
	logic [127:0]		status_data;

	ok = 0;
	if (!cfg.bar_map.resolve_name("h0.pf0.bar0", target, why)) return;
	mmio(target, 0, 64'h1010, 4, '0, '0, status_data, ok, why, 0);
	if (!ok) return;
	if (status_data[31:0] !== 32'h8) begin
		ok  = 0;
		why = $sformatf("AF status expected 0x00000008, got 0x%08h", status_data[31:0]);
		return;
	end
	writes_since_af_read = 0;
endtask

task dpu_cfg_seq::flush_writes(
	output bit		ok,
	output string	why
);
	dpu_bar_target_t				management;
	uvm_sequencer #(pcie_tl_tlp)	management_rc;
	string							keys[$];
	logic [127:0]					ignored;

	ok = 0;
	if (!cfg.bar_map.resolve_name("h0.pf0.bar0", management, why) ||
		!get_rc(management, management_rc, why))
		return;
	foreach (unflushed_target[key]) keys.push_back(key);
	foreach (keys[i]) begin
		if (keys[i] == management_rc.get_full_name())
			read_af_status(ok, why);
		else
			mmio(unflushed_target[keys[i]], 0, unflushed_offset[keys[i]], 4, '0, '0, ignored, ok, why, 0);
		if (!ok) return;
	end
	ok  = 1;
	why = "";
endtask

task dpu_cfg_seq::post_start();
	if (!success) begin
		`uvm_fatal("PROJECT_CONFIG_SEQ", error_msg == "" ? "DUT configuration failed" : error_msg)
	end
endtask

function bit dpu_cfg_seq::completed_step(
	input string	step,
	input bit		ok
);
	if (!ok) begin
		error_msg = {step, ": ", error_msg};
	end

	return ok;
endfunction

task dpu_cfg_seq::configure_bar_table(
	input dpu_cfg_scope	scope,
	output bit			ok,
	output string		why
);
	dpu_table_kind_e	kinds[$] = '{DPU_TABLE_BAR};

	configure_public(kinds, scope, ok, why);
endtask

task dpu_cfg_seq::configure_af(
	input dpu_cfg_scope	scope,
	output bit			ok,
	output string		why
);
	dpu_table_kind_e	kinds[$] = '{DPU_TABLE_AF};

	configure_public(kinds, scope, ok, why);
endtask

task dpu_cfg_seq::configure_pf_vf_map(
	input dpu_cfg_scope	scope,
	output bit			ok,
	output string		why
);
	dpu_table_kind_e	kinds[$] = '{DPU_TABLE_PFVF};

	configure_public(kinds, scope, ok, why);
endtask

task dpu_cfg_seq::configure_bdf_table(
	input dpu_cfg_scope	scope,
	output bit			ok,
	output string		why
);
	dpu_table_kind_e	kinds[$] = '{DPU_TABLE_BDF};

	configure_public(kinds, scope, ok, why);
endtask

task dpu_cfg_seq::configure_completion_bdf_table(
	input dpu_cfg_scope	scope,
	output bit			ok,
	output string		why
);
	dpu_table_kind_e	kinds[$] = '{DPU_TABLE_COMPLETION_BDF};

	configure_public(kinds, scope, ok, why);
endtask

task dpu_cfg_seq::configure_tlp_prefix(
	input dpu_cfg_scope	scope,
	output bit			ok,
	output string		why
);
	dpu_table_kind_e	kinds[$] = '{DPU_TABLE_PREFIX};

	configure_public(kinds, scope, ok, why);
endtask

task dpu_cfg_seq::configure_msix(
	input dpu_cfg_scope	scope,
	output bit			ok,
	output string		why
);
	dpu_table_kind_e	kinds[$] = '{
		DPU_TABLE_MSIX_LINEAR,
		DPU_TABLE_MSIX_INFO,
		DPU_TABLE_MSIX_INTERVAL,
		DPU_TABLE_MSIX_CONTROL,
		DPU_TABLE_MSIX_TABLE
	};
	configure_public(kinds, scope, ok, why);
endtask

task dpu_cfg_seq::enable_msix(
	input dpu_cfg_scope	scope,
	output bit			ok,
	output string		why
);
	dpu_table_kind_e	kinds[$] = '{DPU_TABLE_MSIX_FUNCTION};

	configure_public(kinds, scope, ok, why);
endtask

task dpu_cfg_seq::configure_rdma_notify(
	input dpu_cfg_scope	scope,
	output bit			ok,
	output string		why
);
	dpu_table_kind_e	kinds[$] = '{DPU_TABLE_RDMA_NOTIFY};

	configure_public(kinds, scope, ok, why);
endtask

task dpu_cfg_seq::configure_qsch_rnet(
	input dpu_cfg_scope	scope,
	output bit			ok,
	output string		why
);
	dpu_table_kind_e	kinds[$] = '{DPU_TABLE_RNET};

	configure_public(kinds, scope, ok, why);
endtask

task dpu_cfg_seq::configure_vio_notify(
	input dpu_cfg_scope	selection,
	output bit			ok,
	output string		why
);
	dpu_table_kind_e	kinds[$] = '{DPU_TABLE_NOTIFY};

	configure_queues(kinds, selection, ok, why);
endtask

task dpu_cfg_seq::process_msix_tail(
	input bit		verify,
	output bit		ok,
	output string	why
);
	dpu_msix_linear_entry_t	invalid_entry;
	dpu_table_ctx_t			ctx;
	logic [127:0]			readback;
	bit [63:0]				offset;
	bit [63:0]				address;

	ok  = 0;
	why = "MSI-X linear directory is empty";
	if (cfg.msix_linear_records.size() == 0) return;

	ctx = cfg.msix_linear_records[0].ctx;
	if (ctx.layout.capacity > 2048 || cfg.msix_linear_records.size() > ctx.layout.capacity) begin
		why = "MSI-X linear directory exceeds the single-bank layout";
		return;
	end
	invalid_entry                = '1;
	invalid_entry.reserved_63_35 = '0;
	offset                       = ctx.layout.module_offset + ctx.layout.table_offset;
	if (!cfg.bar_map.check_range(ctx.target, offset, 64'(ctx.layout.capacity) * 8, address, why))
		return;

	for (int	unsigned	row = cfg.msix_linear_records.size(); row < ctx.layout.capacity; row++) begin
		offset = ctx.layout.module_offset + ctx.layout.table_offset + 64'(row) * 8;
		if (verify) begin
			mmio(ctx.target, 0, offset, 8, 0, 0, readback, ok, why);
			if (!ok) return;
			if (readback !== 128'(invalid_entry)) begin
				ok = 0;
				why = $sformatf("MSI-X invalid-row readback mismatch row=%0d offset=0x%016h", row,
								offset);
				return;
			end
		end else begin
			write_table_dwords(ctx.target, offset, 8, 128'(invalid_entry), ok, why);
			if (!ok) return;
		end
	end

	ok  = 1;
	why = "";
endtask

task dpu_cfg_seq::configure_qsch(
	input dpu_cfg_scope	selection,
	output bit			ok,
	output string		why
);
	dpu_table_kind_e	kinds[$] = '{
		DPU_TABLE_Q2TC,
		DPU_TABLE_N2G,
		DPU_TABLE_G2P,
		DPU_TABLE_SPWRR,
		DPU_TABLE_TC_WEIGHT
	};

	if (cfg.qsch_configure_controls) begin
		configure_qsch_mode(selection, ok, why);
		if (!ok) return;
	end

	configure_queues(kinds, selection, ok, why);
endtask

task dpu_cfg_seq::configure_qsch_mode(
	input dpu_cfg_scope	selection,
	output bit			ok,
	output string		why
);
	dpu_table_kind_e	kinds[$] = '{DPU_TABLE_Q2TC};
	dpu_table_item_t	batch[$];
	bit					seen[string];
	logic [127:0]		readback;

	ok = 0;
	if (!cfg.queue_records(selection, kinds, batch, why)) return;

	foreach (batch[i]) begin
		if (seen.exists(batch[i].ctx.target.canonical_name)) continue;
		seen[batch[i].ctx.target.canonical_name] = 1;

		mmio(batch[i].ctx.target, 1, cfg.qsch_mode_offset, 4, 128'(cfg.qsch_mode), 0, readback, ok,
			 why);
		if (!ok) return;
		if (!cfg.verify_readback) continue;

		mmio(batch[i].ctx.target, 0, cfg.qsch_mode_offset, 4, 0, 0, readback, ok, why);
		if (!ok) return;

		if (readback[31:0] !== 32'(cfg.qsch_mode)) begin
			ok = 0;
			why = $sformatf(
				"QSCH mode readback mismatch offset=0x%016h expected=%08h actual=%08h",
				cfg.qsch_mode_offset,
				cfg.qsch_mode,
				readback[31:0]
			);
			return;
		end
	end

	ok  = 1;
	why = "";
endtask

task dpu_cfg_seq::configure_vio_queues(
	input dpu_cfg_scope	selection,
	output bit			ok,
	output string		why
);
	dpu_table_kind_e	kinds[$] = '{DPU_TABLE_VTX, DPU_TABLE_VRX, DPU_TABLE_QUEUE_AUX};

	configure_queues(kinds, selection, ok, why);
endtask

task dpu_cfg_seq::user_prepare_device(
	input dpu_control_cfg_t	item,
	output bit				ok,
	output string			why
);
	ok  = 0;
	why = "required user_prepare_device is not implemented";
endtask

task dpu_cfg_seq::user_configure_af(
	input dpu_control_cfg_t	item,
	output bit				ok,
	output string			why
);
	ok  = 0;
	why = "required user_configure_af is not implemented";
endtask

task dpu_cfg_seq::user_configure_msix_control_entry(
	input dpu_control_cfg_t	item,
	output bit				ok,
	output string			why
);
	ok  = 0;
	why = "required user_configure_msix_control_entry is not implemented";
endtask

task dpu_cfg_seq::user_configure_msix_function(
	input dpu_control_cfg_t	item,
	output bit				ok,
	output string			why
);
	ok  = 0;
	why = "required user_configure_msix_function is not implemented";
endtask

task dpu_cfg_seq::user_quiesce_device(
	input dpu_control_cfg_t	item,
	output bit				ok,
	output string			why
);
	ok  = 0;
	why = "required user_quiesce_device is not implemented";
endtask

task dpu_cfg_seq::user_reset_device(
	input dpu_control_cfg_t	item,
	output bit				ok,
	output string			why
);
	ok  = 0;
	why = "required user_reset_device is not implemented";
endtask

task dpu_cfg_seq::user_configure_bar_mapping_entry(
	input dpu_bar_mapping_cfg_t	item,
	output bit					ok,
	output string				why
);
	ok  = 0;
	why = "required user_configure_bar_mapping_entry is not implemented";
endtask

task dpu_cfg_seq::user_verify_dpu_configuration(
	input dpu_cfg_scope	scope,
	output bit			ok,
	output string		why
);
	ok  = 0;
	why = "required user_verify_dpu_configuration is not implemented";
endtask

task dpu_cfg_seq::user_verify_vio_configuration(
	input dpu_cfg_scope	selection,
	output bit			ok,
	output string		why
);
	dpu_table_kind_e	kinds[$] = '{
		DPU_TABLE_NOTIFY,
		DPU_TABLE_Q2TC,
		DPU_TABLE_N2G,
		DPU_TABLE_G2P,
		DPU_TABLE_SPWRR,
		DPU_TABLE_TC_WEIGHT,
		DPU_TABLE_VTX,
		DPU_TABLE_VRX,
		DPU_TABLE_QUEUE_AUX
	};
	dpu_table_item_t	batch[$];
	bit					seen[string];
	logic [127:0]		readback;
	logic [127:0]		expected;
	logic [127:0]		mask;

	ok = 0;
	if (!cfg.queue_records(selection, kinds, batch, why)) return;

	foreach (batch[i]) begin
		if (seen.exists(batch[i].ctx.record_key)) continue;
		seen[batch[i].ctx.record_key] = 1;

		expected = (batch[i].entry & ~batch[i].enable_mask) | batch[i].enable_value;
		mask     = '1;
		mask     = mask >> (128 - batch[i].ctx.layout.entry_bytes * 8);

		if (batch[i].ctx.kind inside {DPU_TABLE_SPWRR, DPU_TABLE_TC_WEIGHT, DPU_TABLE_QUEUE_AUX}) begin
			mask = cfg.platform_control_mask(batch[i]);
		end

		mmio(batch[i].ctx.target, 0, batch[i].ctx.byte_offset, batch[i].ctx.layout.entry_bytes, 0,
			 0, readback, ok, why);
		if (!ok) return;

		if ((readback & mask) !== (expected & mask)) begin
			ok = 0;
			why = $sformatf(
				"readback mismatch %s BAR offset=0x%016h expected=%032h actual=%032h mask=%032h",
				batch[i].ctx.record_key,
				batch[i].ctx.byte_offset,
				expected,
				readback,
				mask
			);
			return;
		end
	end

	ok  = 1;
	why = "";
endtask

task dpu_cfg_seq::mmio(
	input dpu_bar_target_t	target,
	input bit				writing,
	input logic [63:0]		offset,
	input int unsigned		length,
	input logic [127:0]		data,
	input logic [31:0]		byte_skip_mask,
	output logic [127:0]	result,
	output bit				ok,
	output string			why,
	input bit				check_read_data
);
	pcie_tl_reg_seq					seq;

	uvm_sequencer #(pcie_tl_tlp)	sequencer;
	bit [63:0]						address;

	ok     = 0;
	result = '0;
	why    = "MMIO contains X/Z, unsupported width/alignment or skip-mask";
	if ($isunknown({offset, data, byte_skip_mask}) || !(length inside {4, 8, 12, 16}) || offset[1:0] != 0 ||
			(byte_skip_mask != '1 && (byte_skip_mask >> length) != 0) ||
			(writing && length < 16 && (data >> (8 * length)) != 0))
		return;
	if (cfg.bar_map == null) return;
	if (!cfg.bar_map.check_range(target, offset, length, address, why)) return;
	if (address[11:0] + length > 4096 || !get_rc(target, sequencer, why)) begin
		why = "MMIO crosses 4KB or has no RC sequencer";
		return;
	end
	seq                 = pcie_tl_reg_seq::type_id::create("project_mmio");
	seq.is_write        = writing;
	seq.addr            = address;
	seq.len             = length;
	seq.mask            = byte_skip_mask;
	seq.wdata           = data;
	seq.check_read_data = check_read_data;
	seq.start(sequencer, this);
	ok     = seq.status == PCIE_RW_OK;
	why    = seq.error_msg;
	result = seq.rdata;
	if (ok && writing) begin
		unflushed_target[sequencer.get_full_name()] = target;
		unflushed_offset[sequencer.get_full_name()] = offset;
	end else if (ok) begin
		unflushed_target.delete(sequencer.get_full_name());
		unflushed_offset.delete(sequencer.get_full_name());
	end
	// 当前表写均为完整4B；宽访问和部分/全屏蔽访问不冒充一个完整DWORD，也不额外拆包。
	if (ok && writing && length == 4 && byte_skip_mask == 0 && seq.issued_tlps.size() != 0) begin
		writes_since_af_read++;
		if (writes_since_af_read == 100) read_af_status(ok, why);
	end
endtask

task dpu_cfg_seq::pcie_bar_write(
	input dpu_function_key_t	owner,
	input int unsigned			bar_id,
	input logic [63:0]			offset,
	input int unsigned			length,
	input logic [127:0]			data,
	input logic [31:0]			byte_skip_mask,
	output bit					ok,
	output string				why
);
	dpu_bar_target_t	target;
	logic [127:0]		ignored;

	ok = 0;
	if (cfg.bar_map == null) begin
		why = "public registry not published";
		return;
	end
	if (!cfg.bar_map.resolve_function(owner, bar_id, target, why)) return;
	mmio(target, 1, offset, length, data, byte_skip_mask, ignored, ok, why);
endtask

task dpu_cfg_seq::pcie_bar_read(
	input dpu_function_key_t	owner,
	input int unsigned			bar_id,
	input logic [63:0]			offset,
	input int unsigned			length,
	input logic [31:0]			byte_skip_mask,
	output logic [127:0]		data,
	output bit					ok,
	output string				why
);
	dpu_bar_target_t	target;

	ok   = 0;
	data = '0;
	if (cfg.bar_map == null) begin
		why = "public registry not published";
		return;
	end
	if (!cfg.bar_map.resolve_function(owner, bar_id, target, why)) return;
	mmio(target, 0, offset, length, '0, byte_skip_mask, data, ok, why);
endtask

task dpu_cfg_seq::pcie_bar_write_by_name(
	input string		name,
	input logic [63:0]	offset,
	input int unsigned	length,
	input logic [127:0]	data,
	input logic [31:0]	byte_skip_mask,
	output bit			ok,
	output string		why
);
	dpu_bar_target_t	target;
	logic [127:0]		ignored;

	ok = 0;
	if (cfg.bar_map == null) begin
		why = "public registry not published";
		return;
	end
	if (!cfg.bar_map.resolve_name(name, target, why)) return;
	mmio(target, 1, offset, length, data, byte_skip_mask, ignored, ok, why);
endtask

task dpu_cfg_seq::pcie_table_write_by_name(
	input string		name,
	input logic [63:0]	offset,
	input int unsigned	length,
	input logic [127:0]	data,
	output bit			ok,
	output string		why
);
	dpu_bar_target_t	target;

	ok  = 0;
	why = "public registry not published";

	if (cfg.bar_map == null) begin
		return;
	end

	if (!cfg.bar_map.resolve_name(name, target, why)) begin
		return;
	end

	write_table_dwords(target, offset, length, data, ok, why);
endtask

task dpu_cfg_seq::write_table_dwords(
	input dpu_bar_target_t	target,
	input logic [63:0]		offset,
	input int unsigned		length,
	input logic [127:0]		data,
	output bit				ok,
	output string			why
);
	logic [127:0]					ignored;

	uvm_sequencer #(pcie_tl_tlp)	sequencer;
	bit [ 63:0]						address;

	ok  = 0;
	why = "table write contains X/Z, unsupported width/alignment or excess data";

	if ($isunknown({offset, data}) || !(length inside {4, 8, 12, 16}) || offset[1:0] != 0 ||
			(length < 16 && (data >> (8 * length)) != 0)) begin
		return;
	end

	if (cfg.bar_map == null || !cfg.runtime_ready) begin
		why = "table write requires published registry and PCIe environment";
		return;
	end

	if (!cfg.bar_map.check_range(target, offset, length, address, why)) begin
		return;
	end

	if (address[11:0] + length > 4096 || !get_rc(target, sequencer, why)) begin
		why = "table write crosses 4KB or has no RC sequencer";
		return;
	end

	for (int	dword = int'(length / 4) - 1; dword >= 0; dword--) begin
		mmio(target, 1, offset + 4 * dword, 4, 128'(data[dword*32+:32]), 0, ignored, ok, why);

		if (!ok) begin
			return;
		end
	end
endtask

task dpu_cfg_seq::pcie_bar_read_by_name(
	input string			name,
	input logic [63:0]		offset,
	input int unsigned		length,
	input logic [31:0]		byte_skip_mask,
	output logic [127:0]	data,
	output bit				ok,
	output string			why
);
	dpu_bar_target_t	target;

	ok   = 0;
	data = '0;
	if (cfg.bar_map == null) begin
		why = "public registry not published";
		return;
	end
	if (!cfg.bar_map.resolve_name(name, target, why)) return;
	mmio(target, 0, offset, length, '0, byte_skip_mask, data, ok, why);
endtask

task dpu_cfg_seq::pcie_poll_bar(
	input dpu_function_key_t	owner,
	input int unsigned			bar_id,
	input logic [63:0]			offset,
	input int unsigned			length,
	input logic [127:0]			mask,
	input logic [127:0]			expected,
	input int unsigned			attempts,
	input time					interval,
	output bit					ok,
	output string				why
);
	logic [127:0]	data;

	ok  = 0;
	why = "poll needs finite attempts and known comparison";
	if (attempts == 0 || $isunknown({mask, expected})) return;
	for (int	unsigned	i = 0; i < attempts; i++) begin
		pcie_bar_read(owner, bar_id, offset, length, 0, data, ok, why);
		if (!ok) return;
		if ((data & mask) === (expected & mask)) return;
		if (i + 1 < attempts) #(interval);
	end
	ok  = 0;
	why = "BAR poll exhausted attempts";
endtask

task dpu_cfg_seq::checked_write(
	input dpu_table_item_t	record,
	input logic [127:0]		value,
	input bit				enabling,
	output bit				ok,
	output string			why
);
	dpu_table_item_t	original;
	dpu_table_layout_t	layout;
	logic [127:0]		ignored;
	logic [127:0]		expected;
	bit [63:0]			address;
	bit [63:0]			offset;
	logic [31:0]		control;

	ok  = 0;
	why = "checked table write has no matching frozen record";
	if (!cfg.records.exists(record.ctx.record_key)) return;
	original = cfg.records[record.ctx.record_key];
	expected = enabling ? (original.entry & ~original.enable_mask) | original.enable_value : original.entry;
	if (record.ctx !== original.ctx || record.has_queue != original.has_queue ||
		!dpu_same_function_key(record.owner, original.owner) || (record.has_queue && record.binding !== original.binding) || $isunknown(value) || value !== expected) begin
		why = "checked table context/binding/entry differs from immutable export";
		return;
	end
	if (record.has_queue && !cfg.check_queue(record.binding, why)) return;
	layout = original.ctx.layout;
	if (!cfg.bar_map.check_range(
			original.ctx.target, original.ctx.byte_offset, layout.entry_bytes, address, why
		))
		return;
	if (layout.indirect) begin
		offset = layout.module_offset + layout.data_port;
		if (!cfg.bar_map.check_range(original.ctx.target, offset, layout.entry_bytes, address, why) || !cfg.bar_map.check_range(
				original.ctx.target, layout.module_offset + layout.control_port, 4, address, why
			))
			return;
	end
	if (layout.indirect) begin

		write_table_dwords(original.ctx.target, offset, layout.entry_bytes, value, ok, why);
		control = layout.control_fixed | (original.ctx.table_index << layout.index_shift);

		if (ok) begin
			mmio(original.ctx.target, 1, layout.module_offset + layout.control_port, 4,
				 128'(control), 0, ignored, ok, why);
		end

		if (ok) begin
			mmio(original.ctx.target, 1, layout.module_offset + layout.control_port, 4,
				 128'(control | layout.trigger_mask), 0, ignored, ok, why);
		end

	end else begin
		write_table_dwords(original.ctx.target, original.ctx.byte_offset, layout.entry_bytes, value,
						   ok, why);
	end
endtask

task dpu_cfg_seq::write_bdf(
	input dpu_bdf_cfg_t	item,
	output bit			ok,
	output string		why
);
	dpu_table_item_t	r;

	ok  = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != DPU_TABLE_BDF) return;
	r       = cfg.records[item.ctx.record_key];
	r.ctx   = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin
		why = "typed consumer set changed";
		return;
	end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask

task dpu_cfg_seq::write_completion_bdf(
	input dpu_completion_bdf_cfg_t	item,
	output bit						ok,
	output string					why
);
	dpu_table_item_t	r;

	ok  = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != DPU_TABLE_COMPLETION_BDF)
		return;
	r       = cfg.records[item.ctx.record_key];
	r.ctx   = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin
		why = "typed consumer set changed";
		return;
	end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask

task dpu_cfg_seq::write_pfvf(
	input dpu_pfvf_cfg_t	item,
	output bit				ok,
	output string			why
);
	dpu_table_item_t	r;

	ok  = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != DPU_TABLE_PFVF) return;
	r       = cfg.records[item.ctx.record_key];
	r.ctx   = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin
		why = "typed consumer set changed";
		return;
	end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask

task dpu_cfg_seq::write_tlp_prefix(
	input dpu_tlp_prefix_cfg_t	item,
	output bit					ok,
	output string				why
);
	dpu_table_item_t	r;

	ok  = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != DPU_TABLE_PREFIX) return;
	r       = cfg.records[item.ctx.record_key];
	r.ctx   = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin
		why = "typed consumer set changed";
		return;
	end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask

task dpu_cfg_seq::write_msix_linear(
	input dpu_msix_linear_cfg_t	item,
	output bit					ok,
	output string				why
);
	dpu_table_item_t	r;

	ok  = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != DPU_TABLE_MSIX_LINEAR) return;
	r       = cfg.records[item.ctx.record_key];
	r.ctx   = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin
		why = "typed consumer set changed";
		return;
	end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask

task dpu_cfg_seq::write_msix_info(
	input dpu_msix_info_cfg_t	item,
	output bit					ok,
	output string				why
);
	dpu_table_item_t	r;

	ok  = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != DPU_TABLE_MSIX_INFO) return;
	r       = cfg.records[item.ctx.record_key];
	r.ctx   = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin
		why = "typed consumer set changed";
		return;
	end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask

task dpu_cfg_seq::write_msix_interval(
	input dpu_msix_interval_cfg_t	item,
	output bit						ok,
	output string					why
);
	dpu_table_item_t	r;

	ok  = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != DPU_TABLE_MSIX_INTERVAL)
		return;
	r       = cfg.records[item.ctx.record_key];
	r.ctx   = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin
		why = "typed consumer set changed";
		return;
	end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask

task dpu_cfg_seq::write_msix_table(
	input dpu_msix_table_cfg_t	item,
	output bit					ok,
	output string				why
);
	dpu_table_item_t	r;

	ok  = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != DPU_TABLE_MSIX_TABLE) return;
	r       = cfg.records[item.ctx.record_key];
	r.ctx   = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin
		why = "typed consumer set changed";
		return;
	end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask

task dpu_cfg_seq::write_qsch_q2tc(
	input dpu_qsch_q2tc_cfg_t	item,
	output bit					ok,
	output string				why
);
	dpu_table_item_t	r;

	ok  = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != DPU_TABLE_Q2TC) return;
	r       = cfg.records[item.ctx.record_key];
	r.ctx   = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin
		why = "typed consumer set changed";
		return;
	end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask

task dpu_cfg_seq::write_qsch_n2g(
	input dpu_qsch_n2g_cfg_t	item,
	output bit					ok,
	output string				why
);
	dpu_table_item_t	r;

	ok  = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != DPU_TABLE_N2G) return;
	r       = cfg.records[item.ctx.record_key];
	r.ctx   = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin
		why = "typed consumer set changed";
		return;
	end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask

task dpu_cfg_seq::write_qsch_g2p(
	input dpu_qsch_g2p_cfg_t	item,
	output bit					ok,
	output string				why
);
	dpu_table_item_t	r;

	ok  = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != DPU_TABLE_G2P) return;
	r       = cfg.records[item.ctx.record_key];
	r.ctx   = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin
		why = "typed consumer set changed";
		return;
	end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask

task dpu_cfg_seq::write_rdma_notify(
	input dpu_rdma_notify_cfg_t	item,
	output bit					ok,
	output string				why
);
	dpu_table_item_t	r;

	ok  = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != DPU_TABLE_RDMA_NOTIFY) return;
	r       = cfg.records[item.ctx.record_key];
	r.ctx   = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin
		why = "typed consumer set changed";
		return;
	end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask

task dpu_cfg_seq::write_qsch_rnet(
	input dpu_qsch_rnet_cfg_t	item,
	output bit					ok,
	output string				why
);
	dpu_table_item_t	r;

	ok  = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != DPU_TABLE_RNET) return;
	r       = cfg.records[item.ctx.record_key];
	r.ctx   = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin
		why = "typed consumer set changed";
		return;
	end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask

task dpu_cfg_seq::write_vtx(
	input dpu_vtx_cfg_t	item,
	output bit			ok,
	output string		why
);
	dpu_table_item_t	r;

	ok  = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != DPU_TABLE_VTX) return;
	r         = cfg.records[item.ctx.record_key];
	r.ctx     = item.ctx;
	r.binding = item.binding;
	r.owner   = item.binding.service_key.function_key;
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask

task dpu_cfg_seq::write_vrx(
	input dpu_vrx_cfg_t	item,
	output bit			ok,
	output string		why
);
	dpu_table_item_t	r;

	ok  = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != DPU_TABLE_VRX) return;
	r         = cfg.records[item.ctx.record_key];
	r.ctx     = item.ctx;
	r.binding = item.binding;
	r.owner   = item.binding.service_key.function_key;
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask

task dpu_cfg_seq::write_vio_notify(
	input dpu_vio_notify_cfg_t	item,
	output bit					ok,
	output string				why
);
	dpu_table_item_t	r;

	ok  = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != DPU_TABLE_NOTIFY) return;
	r         = cfg.records[item.ctx.record_key];
	r.ctx     = item.ctx;
	r.binding = item.binding;
	r.owner   = item.binding.service_key.function_key;
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask

task dpu_cfg_seq::dispatch_record(
	input dpu_table_item_t	record,
	output bit				ok,
	output string			why
);
	ok  = 0;
	why = "unsupported table category";
	case (record.ctx.kind)
		DPU_TABLE_BDF: begin
			dpu_bdf_cfg_t	item;

			item.ctx       = record.ctx;
			item.entry     = dpu_bdf_entry_t'(record.entry);
			item.owner     = record.owner;
			item.consumers = record.consumers;
			write_bdf(item, ok, why);
		end
		DPU_TABLE_COMPLETION_BDF: begin
			dpu_completion_bdf_cfg_t	item;

			item.ctx       = record.ctx;
			item.entry     = dpu_completion_bdf_entry_t'(record.entry);
			item.owner     = record.owner;
			item.consumers = record.consumers;
			write_completion_bdf(item, ok, why);
		end
		DPU_TABLE_PFVF: begin
			dpu_pfvf_cfg_t	item;

			item.ctx       = record.ctx;
			item.entry     = dpu_pfvf_entry_t'(record.entry);
			item.owner     = record.owner;
			item.consumers = record.consumers;
			write_pfvf(item, ok, why);
		end
		DPU_TABLE_PREFIX: begin
			dpu_tlp_prefix_cfg_t	item;

			item.ctx       = record.ctx;
			item.entry     = dpu_tlp_prefix_entry_t'(record.entry);
			item.owner     = record.owner;
			item.consumers = record.consumers;
			write_tlp_prefix(item, ok, why);
		end
		DPU_TABLE_MSIX_LINEAR: begin
			dpu_msix_linear_cfg_t	item;

			item.ctx       = record.ctx;
			item.entry     = dpu_msix_linear_entry_t'(record.entry);
			item.owner     = record.owner;
			item.consumers = record.consumers;
			write_msix_linear(item, ok, why);
		end
		DPU_TABLE_MSIX_INFO: begin
			dpu_msix_info_cfg_t	item;

			item.ctx       = record.ctx;
			item.entry     = dpu_msix_info_entry_t'(record.entry);
			item.owner     = record.owner;
			item.consumers = record.consumers;
			write_msix_info(item, ok, why);
		end
		DPU_TABLE_MSIX_INTERVAL: begin
			dpu_msix_interval_cfg_t	item;

			item.ctx       = record.ctx;
			item.entry     = dpu_msix_interval_entry_t'(record.entry);
			item.owner     = record.owner;
			item.consumers = record.consumers;
			write_msix_interval(item, ok, why);
		end
		DPU_TABLE_MSIX_TABLE: begin
			dpu_msix_table_cfg_t	item;

			item.ctx       = record.ctx;
			item.entry     = dpu_msix_table_entry_t'(record.entry);
			item.owner     = record.owner;
			item.consumers = record.consumers;
			write_msix_table(item, ok, why);
		end
		DPU_TABLE_Q2TC: begin
			dpu_qsch_q2tc_cfg_t	item;

			item.ctx       = record.ctx;
			item.entry     = dpu_qsch_q2tc_entry_t'(record.entry);
			item.owner     = record.owner;
			item.consumers = record.consumers;
			write_qsch_q2tc(item, ok, why);
		end
		DPU_TABLE_N2G: begin
			dpu_qsch_n2g_cfg_t	item;

			item.ctx       = record.ctx;
			item.entry     = dpu_qsch_n2g_entry_t'(record.entry);
			item.owner     = record.owner;
			item.consumers = record.consumers;
			write_qsch_n2g(item, ok, why);
		end
		DPU_TABLE_G2P: begin
			dpu_qsch_g2p_cfg_t	item;

			item.ctx       = record.ctx;
			item.entry     = dpu_qsch_g2p_entry_t'(record.entry);
			item.owner     = record.owner;
			item.consumers = record.consumers;
			write_qsch_g2p(item, ok, why);
		end
		DPU_TABLE_RDMA_NOTIFY: begin
			dpu_rdma_notify_cfg_t	item;

			item.ctx       = record.ctx;
			item.entry     = dpu_rdma_notify_entry_t'(record.entry);
			item.owner     = record.owner;
			item.consumers = record.consumers;
			write_rdma_notify(item, ok, why);
		end
		DPU_TABLE_RNET: begin
			dpu_qsch_rnet_cfg_t	item;

			item.ctx       = record.ctx;
			item.entry     = dpu_qsch_rnet_entry_t'(record.entry);
			item.owner     = record.owner;
			item.consumers = record.consumers;
			write_qsch_rnet(item, ok, why);
		end
		DPU_TABLE_VTX: begin
			dpu_vtx_cfg_t	item;

			item.ctx     = record.ctx;
			item.entry   = dpu_vtx_entry_t'(record.entry);
			item.binding = record.binding;
			write_vtx(item, ok, why);
		end
		DPU_TABLE_VRX: begin
			dpu_vrx_cfg_t	item;

			item.ctx     = record.ctx;
			item.entry   = dpu_vrx_entry_t'(record.entry);
			item.binding = record.binding;
			write_vrx(item, ok, why);
		end
		DPU_TABLE_NOTIFY: begin
			dpu_vio_notify_cfg_t	item;

			item.ctx     = record.ctx;
			item.entry   = dpu_vio_notify_entry_t'(record.entry);
			item.binding = record.binding;
			write_vio_notify(item, ok, why);
		end
		DPU_TABLE_QUEUE_AUX: begin
			dpu_queue_control_cfg_t	item;

			item.ctx           = record.ctx;
			item.binding       = record.binding;
			item.value         = record.entry;
			item.writable_mask = cfg.platform_control_mask(record);
			write_queue_aux(item, ok, why);
		end
		DPU_TABLE_BAR: begin
			dpu_bar_mapping_cfg_t	item;

			item     = cfg.frozen_bar_groups[record.ctx.table_index];
			item.ctx = record.ctx;
			user_configure_bar_mapping_entry(item, ok, why);
		end
		default: begin
			dpu_control_cfg_t	item;

			item.ctx                = record.ctx;
			item.owner              = record.owner;
			item.consumers          = record.consumers;
			item.consumers_complete = 1;
			item.value              = record.entry;
			item.writable_mask      = cfg.platform_control_mask(record);
			case (record.ctx.kind)
				DPU_TABLE_AF: user_configure_af(item, ok, why);
				DPU_TABLE_MSIX_CONTROL: user_configure_msix_control_entry(item, ok, why);
				DPU_TABLE_MSIX_FUNCTION: user_configure_msix_function(item, ok, why);
				DPU_TABLE_SPWRR: write_control(item, ok, why);
				DPU_TABLE_TC_WEIGHT: write_control(item, ok, why);

				default: ;
			endcase
		end
	endcase
endtask

task dpu_cfg_seq::write_control(
	input dpu_control_cfg_t	item,
	output bit				ok,
	output string			why
);
	dpu_table_item_t	r;

	ok  = 0;
	why = "control has no matching frozen record";
	if (!cfg.records.exists(item.ctx.record_key)) return;
	r = cfg.records[item.ctx.record_key];
	if (!(r.ctx.kind inside {DPU_TABLE_AF, DPU_TABLE_MSIX_CONTROL, DPU_TABLE_MSIX_FUNCTION, DPU_TABLE_SPWRR, DPU_TABLE_TC_WEIGHT}) ||
		item.writable_mask !== cfg.platform_control_mask(r) || item.consumers != r.consumers)
		return;
	r.ctx   = item.ctx;
	r.owner = item.owner;
	checked_write(r, item.value, 0, ok, why);
endtask

task dpu_cfg_seq::write_queue_aux(
	input dpu_queue_control_cfg_t	item,
	output bit						ok,
	output string					why
);
	dpu_table_item_t	r;

	ok  = 0;
	why = "queue auxiliary control has no matching frozen record";
	if (!cfg.records.exists(item.ctx.record_key)) return;
	r = cfg.records[item.ctx.record_key];
	if (r.ctx.kind != DPU_TABLE_QUEUE_AUX || item.writable_mask !== cfg.platform_control_mask(r))
		return;
	r.ctx     = item.ctx;
	r.binding = item.binding;
	r.owner   = item.binding.service_key.function_key;
	checked_write(r, item.value, 0, ok, why);
endtask

task dpu_cfg_seq::configure_public(
	input dpu_table_kind_e	kinds[$],
	input dpu_cfg_scope		scope,
	output bit				ok,
	output string			why
);
	dpu_table_item_t	selected[$];
	dpu_table_item_t	batch[$];

	ok = 0;
	foreach (kinds[k]) begin
		if (!cfg.public_records(kinds[k], scope, selected, why)) return;
		foreach (selected[i]) batch.push_back(selected[i]);
	end
	write_records(batch, ok, why);
endtask

task dpu_cfg_seq::configure_queues(
	input dpu_table_kind_e	kinds[$],
	input dpu_cfg_scope		selection,
	output bit				ok,
	output string			why
);
	dpu_table_item_t	batch[$];

	ok = 0;
	if (!cfg.queue_records(selection, kinds, batch, why)) return;
	write_records(batch, ok, why);
endtask

task dpu_cfg_seq::write_records(
	input dpu_table_item_t	batch[$],
	output bit				ok,
	output string			why
);
	dpu_bar_target_t	notify_targets[string];
	dpu_table_kind_e	notify_kinds[string];
	bit					seen[string];
	bit [63:0]			address;

	ok = 0;
	foreach (batch[i]) begin
		if (!cfg.remember_record(batch[i], why)) return;
		if (batch[i].ctx.kind inside {DPU_TABLE_NOTIFY, DPU_TABLE_RDMA_NOTIFY}) begin
			string	target_key;

			if (!cfg.bar_map.check_range(batch[i].ctx.target, notify_ready_offset(batch[i].ctx.kind), 4,
										 address, why))
				return;
			target_key                 = {batch[i].ctx.target.canonical_name, ":", batch[i].ctx.kind.name()};
			notify_targets[target_key] = batch[i].ctx.target;
			notify_kinds[target_key]   = batch[i].ctx.kind;
		end
	end

	foreach (batch[i]) begin
		string	key;

		key = batch[i].ctx.record_key;
		if (seen.exists(key)) continue;
		seen[key] = 1;
		dispatch_record(cfg.records[key], ok, why);
		if (!ok) begin
			why = {key, ": ", why};
			return;
		end
	end

	foreach (notify_targets[target_key]) begin
		enable_notify(notify_targets[target_key], notify_kinds[target_key], ok, why);
		if (!ok) return;
	end
	ok  = 1;
	why = "";
endtask

function bit [63:0] dpu_cfg_seq::notify_ready_offset(input dpu_table_kind_e	kind);
	return kind == DPU_TABLE_RDMA_NOTIFY ? 64'h0008_0048 : 64'h0008_0044;
endfunction

task dpu_cfg_seq::enable_notify(
	input dpu_bar_target_t	target,
	input dpu_table_kind_e	kind,
	output bit				ok,
	output string			why
);
	logic [127:0]	unused_readback;

	mmio(target, 1, notify_ready_offset(kind), 4, 128'h1, 0, unused_readback, ok, why);
endtask

task dpu_cfg_seq::enable_vio_queues(
	input dpu_cfg_scope	selection,
	output bit			ok,
	output string		why
);
	dpu_table_item_t		batch[$];
	dpu_table_kind_e		kinds[$] = '{DPU_TABLE_VTX, DPU_TABLE_VRX};
	dpu_queue_control_cfg_t	item;

	ok = 0;
	if (!cfg.queue_records(selection, kinds, batch, why)) return;
	foreach (batch[i]) if (!cfg.remember_record(batch[i], why)) return;

	foreach (batch[i]) begin
		item.ctx           = batch[i].ctx;
		item.binding       = batch[i].binding;
		item.value         = (batch[i].entry & ~batch[i].enable_mask) | batch[i].enable_value;
		item.writable_mask = batch[i].enable_mask;
		write_enabled_queue(item, ok, why);
		if (!ok) return;
	end
	ok  = 1;
	why = "";
endtask

task dpu_cfg_seq::verify_dpu_configuration(
	input dpu_cfg_scope	scope,
	output bit			ok,
	output string		why
);
	ok  = 0;
	why = "public verification scope is missing";
	if (scope == null) return;
	if (!scope.validate(cfg.device_snapshot, why)) return;

	user_verify_dpu_configuration(scope, ok, why);
endtask

task dpu_cfg_seq::verify_function_configuration(
	input dpu_cfg_scope	bdf_scope,
	input dpu_cfg_scope	msix_scope,
	output bit			ok,
	output string		why
);
	dpu_table_kind_e	kinds[$] = '{
		DPU_TABLE_BDF,
		DPU_TABLE_MSIX_LINEAR,
		DPU_TABLE_MSIX_INFO,
		DPU_TABLE_MSIX_INTERVAL,
		DPU_TABLE_MSIX_TABLE
	};
	dpu_table_item_t	batch[$];
	dpu_cfg_scope		scope;
	bit					seen[string];
	logic [127:0]		readback;

	ok = 0;
	foreach (kinds[k]) begin
		scope = kinds[k] == DPU_TABLE_BDF ? bdf_scope : msix_scope;
		if (scope == null) continue;
		if (!cfg.public_records(kinds[k], scope, batch, why)) return;
		foreach (batch[i]) begin
			if (seen.exists(batch[i].ctx.record_key)) continue;
			seen[batch[i].ctx.record_key] = 1;
			mmio(batch[i].ctx.target, 0, batch[i].ctx.byte_offset, batch[i].ctx.layout.entry_bytes,
				 0, 0, readback, ok, why);
			if (!ok) return;
			if (readback !== batch[i].entry) begin
				ok = 0;
				why = $sformatf(
					"readback mismatch %s BAR offset=0x%016h expected=%032h actual=%032h",
					batch[i].ctx.record_key,
					batch[i].ctx.byte_offset,
					batch[i].entry,
					readback
				);
				return;
			end
		end
	end

	ok  = 1;
	why = "";
endtask

task dpu_cfg_seq::verify_vio_configuration(
	input dpu_cfg_scope	selection,
	output bit			ok,
	output string		why
);
	ok = 0;
	if (selection == null || !selection.validate(cfg.device_snapshot, why)) return;

	user_verify_vio_configuration(selection, ok, why);
endtask

task dpu_cfg_seq::write_enabled_queue(
	input dpu_queue_control_cfg_t	item,
	output bit						ok,
	output string					why
);
	dpu_table_item_t	r;

	ok  = 0;
	why = "queue enable has no frozen typed record";
	if (!cfg.records.exists(item.ctx.record_key)) return;
	r = cfg.records[item.ctx.record_key];
	if (!r.has_queue || !(r.ctx.kind inside {DPU_TABLE_VTX, DPU_TABLE_VRX}) ||
		item.writable_mask !== r.enable_mask)
		return;
	r.ctx     = item.ctx;
	r.binding = item.binding;
	r.owner   = item.binding.service_key.function_key;
	checked_write(r, item.value, 1, ok, why);
endtask

task dpu_cfg_seq::read_msix_pba(
	input dpu_state_query_t		item,
	output dpu_msix_pba_word_t	value,
	output bit					ok,
	output string				why
);
	dpu_state_query_t	canonical;
	logic [127:0]		data;

	ok    = 0;
	value = '0;
	if (!cfg.get_state_context(
			DPU_TABLE_MSIX_PBA, item.owner, item.ctx.table_index, canonical, why
		))
		return;
	if (canonical.ctx !== item.ctx) begin
		why = "PBA context differs from frozen layout";
		return;
	end
	mmio(item.ctx.target, 0, item.ctx.byte_offset, 8, 0, 0, data, ok, why);
	if (ok) value.pending = data[63:0];
endtask

task dpu_cfg_seq::read_msix_stat(
	input dpu_state_query_t	item,
	output dpu_msix_stat_t	value,
	output bit				ok,
	output string			why
);
	dpu_state_query_t	canonical;

	ok    = 0;
	value = '0;
	if (!cfg.get_state_context(
			DPU_TABLE_MSIX_STAT, item.owner, item.ctx.table_index, canonical, why
		))
		return;
	if (canonical.ctx !== item.ctx) begin
		why = "state context differs from frozen layout";
		return;
	end
	user_read_msix_stat(item, value, ok, why);
endtask

task dpu_cfg_seq::user_read_msix_stat(
	input dpu_state_query_t	item,
	output dpu_msix_stat_t	value,
	output bit				ok,
	output string			why
);
	value = '0;
	ok    = 0;
	why   = "required user_read_msix_stat is not implemented";
endtask

task dpu_cfg_seq::read_pfvf_drop_status(
	input dpu_state_query_t			item,
	output dpu_pfvf_drop_status_t	value,
	output bit						ok,
	output string					why
);
	dpu_state_query_t	canonical;

	ok    = 0;
	value = '0;
	if (!cfg.get_state_context(
			DPU_TABLE_PFVF_DROP, item.owner, item.ctx.table_index, canonical, why
		))
		return;
	if (canonical.ctx !== item.ctx) begin
		why = "state context differs from frozen layout";
		return;
	end
	user_read_pfvf_drop_status(item, value, ok, why);
endtask

task dpu_cfg_seq::user_read_pfvf_drop_status(
	input dpu_state_query_t			item,
	output dpu_pfvf_drop_status_t	value,
	output bit						ok,
	output string					why
);
	value = '0;
	ok    = 0;
	why   = "required user_read_pfvf_drop_status is not implemented";
endtask

task dpu_cfg_seq::clear_pfvf_drop_status(
	input dpu_pfvf_drop_clear_cfg_t	item,
	output bit						ok,
	output string					why
);
	dpu_state_query_t	canonical;

	ok = 0;
	if (!cfg.get_state_context(
			DPU_TABLE_PFVF_DROP, item.owner, item.ctx.table_index, canonical, why
		))
		return;
	if (canonical.ctx !== item.ctx || $isunknown(item.entry)) begin
		why = "invalid W1C context/mask";
		return;
	end
	user_clear_pfvf_drop_status(item, ok, why);
endtask

task dpu_cfg_seq::user_clear_pfvf_drop_status(
	input dpu_pfvf_drop_clear_cfg_t	item,
	output bit						ok,
	output string					why
);
	ok  = 0;
	why = "required user_clear_pfvf_drop_status is not implemented";
endtask

task dpu_cfg_seq::prepare_queues(
	output bit		ok,
	output string	why
);
	selection = null;
	ok        = 1;
	why       = "";
endtask

function void dpu_cfg_seq::commit_queues(
	output bit		ok,
	output string	why
);
	ok  = 1;
	why = "";
endfunction

function bit dpu_cfg_seq::get_rc(
	input dpu_bar_target_t				target,
	output uvm_sequencer#(pcie_tl_tlp)	sequencer,
	output string						why
);
	dpu_pcie_bar_map	map;

	sequencer = null;
	why       = "DPU cfg has no PCIe BAR map";
	if (cfg == null || !$cast(map, cfg.bar_map) || map == null) return 0;
	return map.get_sequencer(target, sequencer, why);
endfunction
