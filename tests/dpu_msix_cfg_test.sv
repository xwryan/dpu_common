// dpu_env_cfg 的 MSI-X 聚焦测试：真实 resolver、BAR map 与 publish；不分配 ring、不访问 DUT。
// 向量租约接在 resolver 记录的向量块和已登记消息之后，依次接续，越界的租约不占用向量；publish 前后都可租。
// 同一 Host 上拥有消息的 Function 共用 pfvf 时 publish 拒绝；给出各自 pfvf 后线性目录按 Host/pfvf/local 排序。
// 租过向量的 Function 即使只有轮询 service 也进入 MSI-X 编程范围。
module dpu_msix_cfg_test;
	import uvm_pkg::*;
	import dpu_resource_pkg::*;
	import aip_core_pkg::*;
	`include "uvm_macros.svh"

	// 测试平台的 PFVF 关系：没有 VF，每个 PF 族只有 PF 本身，pfvf 取参数原值。
	class msix_test_cfg extends dpu_env_cfg;
		function new(string	name = "msix_test_cfg");
			super.new(name);
		endfunction

		virtual function bit validate_pfvf_relationship(
			input dpu_pfvf_relationship_t	family,
			output string					why
		);
			why = family.functions.size() == 1 ? "" : "fixture PF families have no VFs";
			return family.functions.size() == 1;
		endfunction
	endclass

	// 只接住参数加载的 PROJECT_CFG fatal 并记下消息；其他报告照旧。
	class msix_param_catcher extends uvm_report_catcher;
		string	messages[$];

		function new(string	name = "msix_param_catcher");
			super.new(name);
		endfunction

		virtual function action_e catch();
			if (get_severity() != UVM_FATAL || get_id() != "PROJECT_CFG") return THROW;
			messages.push_back(get_message());
			return CAUGHT;
		endfunction
	endclass

	function automatic void check(input bit	ok, input string	why);
		if (!ok) `uvm_fatal("MSIX_TEST", why)
	endfunction

	function automatic dpu_function_key_t pf(input int unsigned	host, input int unsigned	pf_id);
		return '{host_id: host, pf_id: pf_id, kind: DPU_FUNCTION_PF, vf_id: 0};
	endfunction

	// 显式消息：同一地址，data 各不相同，同一 Host 的消息不混淆。
	function automatic dpu_msix_message_t make_message(
		input dpu_function_key_t	owner,
		input int unsigned			local_vector,
		input int unsigned			global_vector,
		input bit [31:0]			data,
		input bit					masked = 0
	);
		return '{owner: owner, local_vector: local_vector, global_vector: global_vector, address: 64'h1_0000_1000,
			data: data, masked: masked};
	endfunction

	// 两个 Host、各两个 PF，每个 PF 一个 VIO service（qpair 数各不相同；msix_services=0 时都走轮询），PF1 的路由由
	// 参数给出。消息模板按 Function 取不同 data 基址，同一 Host 的消息互不混淆；authored=1 时另登记一条块外的显式消息。
	// publish_now=1 时返回 publish 的结果，否则只解析、冻结快照与 BAR map。
	function automatic bit fixture(
		input bit					authored,
		input bit					publish_now,
		output dpu_env_cfg			cfg,
		output dpu_device_snapshot	device,
		output dpu_resource_snapshot	resources,
		output dpu_bar_map			map,
		output string				why,
		input bit					msix_services = 1
	);
		msix_test_cfg				test_cfg;
		dpu_configuration_resolver	resolver;
		dpu_placement_diagnostic	diagnostic;

		test_cfg              = new("msix_cfg");
		cfg                   = test_cfg;
		cfg.hosts             = 2;
		cfg.pfs_per_host      = 2;
		cfg.reg_target        = "h0.pf0.bar0";
		cfg.load_params();
		foreach (cfg.device_cfg.functions[f]) begin
			dpu_vio_service_t	service;

			service.service_key = '{function_key: cfg.device_cfg.functions[f].key,
				service_kind: DPU_SERVICE_VIO_NET, service_instance_id: 0};
			service.enabled     = 1;
			service.tx_enable   = 1;
			service.rx_enable   = 1;
			service.msix_enable = msix_services;
			service.qpairs      = 1 + f;
			cfg.add_vio_service(service);
		end
		if (authored) cfg.messages.push_back(make_message(pf(1, 0), 40, 100, 'habc));
		resolver = new("resolver");
		check(resolver.resolve(cfg.device_cfg, cfg.placement_cfg, device, resources, diagnostic),
			{"resolve: ", diagnostic.message});
		map = new("map");
		check(map.initialize(device, 1, why) && map.freeze(why), {"BAR map: ", why});
		return !publish_now || cfg.publish(device, resources, map, why);
	endfunction

	// 向量块按驱动布局独立核对（LAN = 本 Function 最大 local 向量 + 1，再加 mailbox，AF 另加额外向量区，块按 Function
	// 顺序连续）；租约起点取块末尾与显式消息的较大者，local 起点取本 Function 的块大小与消息。
	function automatic void check_lease(
		input dpu_env_cfg			cfg,
		input dpu_device_snapshot	device,
		input dpu_resource_snapshot	resources,
		input bit					authored
	);
		dpu_msix_vector_block_t	blocks[$];
		dpu_vio_qpair_binding_t	pairs[$];
		dpu_dut_caps			caps;
		dpu_function_key_t		af;
		dpu_bar_pair_lease_t	af_bar;
		dpu_env_cfg				unpublished;
		int unsigned			block_count[string];
		int unsigned			block_end;
		int unsigned			first;
		int unsigned			global_base;
		int unsigned			local_base;
		string					why;

		caps = device.snapshot_dut_caps();
		check(device.get_expected_af(af, af_bar, why), why);
		resources.list_msix_vector_blocks(blocks);
		resources.list_vio_bindings(pairs);
		check(blocks.size() == 4, "every Function with VIO qpairs owns one vector block");
		block_end = 0;
		foreach (blocks[b]) begin
			int unsigned	lan;
			string			name;

			lan  = 0;
			name = dpu_function_key_name(blocks[b].function_key);
			foreach (pairs[p])
				if (dpu_same_function_key(pairs[p].service_key.function_key, blocks[b].function_key) &&
					pairs[p].local_msix_vector_id + 1 > lan)
					lan = pairs[p].local_msix_vector_id + 1;
			check(lan != 0 && blocks[b].vector_count == lan + caps.mailbox_msix_vectors +
				(dpu_same_function_key(blocks[b].function_key, af) ? caps.af_extra_msix_vectors : 0),
				{"vector block size differs from the driver layout: ", name});
			check(blocks[b].global_base == block_end, {"vector blocks are not contiguous in Function order: ", name});
			block_end += blocks[b].vector_count;
			block_count[name] = blocks[b].vector_count;
		end
		first = authored ? 101 : block_end;
		check(cfg.lease_msix_vectors(device, resources, pf(1, 1), 3, global_base, local_base, why) &&
			global_base == first && local_base == block_count[dpu_function_key_name(pf(1, 1))], {"first lease: ", why});
		check(cfg.lease_msix_vectors(device, resources, pf(0, 0), 2, global_base, local_base, why) &&
			global_base == first + 3 && local_base == block_count[dpu_function_key_name(pf(0, 0))],
			{"AF lease follows its extra area: ", why});
		check(!cfg.lease_msix_vectors(device, resources, pf(0, 0), 64, global_base, local_base, why) && why != "" &&
			global_base == 0, "lease beyond 64 local vectors accepted");
		check(!cfg.lease_msix_vectors(device, resources, pf(0, 0), 0, global_base, local_base, why),
			"empty lease accepted");
		check(!cfg.lease_msix_vectors(device, resources, pf(2, 0), 1, global_base, local_base, why),
			"lease for an unknown Function accepted");
		check(cfg.lease_msix_vectors(device, resources, pf(1, 1), 1, global_base, local_base, why) &&
			global_base == first + 5 && local_base == block_count[dpu_function_key_name(pf(1, 1))] + 3,
			{"rejected leases took vectors or a second lease did not continue: ", why});
		if (authored)
			check(cfg.lease_msix_vectors(device, resources, pf(1, 0), 1, global_base, local_base, why) &&
				global_base == first + 6 && local_base == 41, {"explicit message did not move the local start: ", why});
		unpublished = new("unpublished");
		check(!unpublished.lease_msix_vectors(null, resources, pf(0, 0), 1, global_base, local_base, why) &&
			why != "", "lease without a device snapshot accepted");
	endfunction

	// 选出 MSI-X 范围后的线性目录：行按 {Host, pfvf, local} 升序，每行的 Host/pfvf/local/global 取自
	// 冻结消息和该 Function 的 pfvf 参数，且覆盖全部消息。
	function automatic void check_linear(input dpu_env_cfg	cfg, input int unsigned	pfvf[string]);
		dpu_cfg_scope	scope;
		string			why;
		bit [21:0]		previous;

		check(cfg.select_msix_scope(scope, why) && scope != null, {"select_msix_scope: ", why});
		check(cfg.msix_linear_records.size() == cfg.frozen_messages.size(), "linear directory misses messages");
		foreach (cfg.msix_linear_records[i]) begin
			dpu_msix_linear_entry_t	entry;
			string					name;
			bit						found;

			entry = dpu_msix_linear_entry_t'(cfg.msix_linear_records[i].entry);
			name  = dpu_function_key_name(cfg.msix_linear_records[i].owner);
			check(entry.host_id == cfg.msix_linear_records[i].owner.host_id && entry.pfvf_id == pfvf[name],
				{"linear row Host/pfvf differs from the Function parameters: ", name});
			found = 0;
			foreach (cfg.frozen_messages[m])
				if (dpu_same_function_key(cfg.frozen_messages[m].owner, cfg.msix_linear_records[i].owner) &&
					cfg.frozen_messages[m].local_vector == entry.local_msix_idx &&
					cfg.frozen_messages[m].global_vector == entry.global_msix_idx)
					found = 1;
			check(found, {"linear row has no frozen message: ", name});
			check(i == 0 || {entry.host_id, entry.pfvf_id, entry.local_msix_idx} > previous,
				"linear rows are not sorted by Host, pfvf and local vector");
			check(cfg.msix_linear_records[i].ctx.table_index == i, "linear row index is not its sorted position");
			previous = {entry.host_id, entry.pfvf_id, entry.local_msix_idx};
		end
	endfunction

	// 参数检查各用一份新 cfg：越界 pfvf、没有路由策略的 Function 给 pfvf、VF 给 first_vf_offset。
	function automatic void check_param(input string	key, input string	value, input int unsigned	vfs_per_pf,
										input string	expected);
		msix_param_catcher	catcher;
		dpu_env_cfg			cfg;

		catcher = new();
		uvm_report_cb::add(null, catcher);
		aip_cmdline_override::set_val(key, value);
		cfg            = new("param_cfg");
		cfg.hosts      = 2;
		cfg.pfs_per_host = 2;
		cfg.vfs_per_pf = vfs_per_pf;
		cfg.load_params();
		aip_cmdline_override::clear(key);
		uvm_report_cb::delete(null, catcher);
		check(catcher.messages.size() >= 1 && catcher.messages[0] == expected,
			{key, "=", value, " was not rejected with: ", expected});
	endfunction

	// 服务都走轮询，也没有 control_irq：只有租过向量的 Function 进入 MSI-X 编程范围，它的冻结消息（含 masked 的那条）
	// 都有 linear 行，TABLE 行带 mask。租约在 publish 之前取，与平台在 env build 里租向量相同。
	function automatic void check_lease_scope();
		dpu_env_cfg				cfg;
		dpu_device_snapshot		device;
		dpu_resource_snapshot	resources;
		dpu_bar_map				map;
		dpu_cfg_scope			scope;
		dpu_table_item_t		rows[$];
		int unsigned			global_base;
		int unsigned			local_base;
		bit						linear[int unsigned];
		bit						masked_row;
		string					why;

		check(fixture(0, 0, cfg, device, resources, map, why, 0), why);
		check(cfg.lease_msix_vectors(device, resources, pf(1, 1), 2, global_base, local_base, why), why);
		cfg.messages.push_back(make_message(pf(1, 1), local_base, global_base, 'h5000));
		cfg.messages.push_back(make_message(pf(1, 1), local_base + 1, global_base + 1, 'h5001, 1));
		check(cfg.publish(device, resources, map, why), {"publish with leased messages: ", why});
		check(cfg.select_msix_scope(scope, why) && scope != null, {"leased Function did not join the MSI-X scope: ", why});
		foreach (cfg.msix_linear_records[i]) begin
			dpu_msix_linear_entry_t	entry;

			entry = dpu_msix_linear_entry_t'(cfg.msix_linear_records[i].entry);
			check(dpu_same_function_key(cfg.msix_linear_records[i].owner, pf(1, 1)),
				"a polling Function without a lease joined the MSI-X scope");
			linear[entry.global_msix_idx] = 1;
		end
		check(linear.exists(global_base) && linear.exists(global_base + 1), "leased vectors have no linear rows");
		check(cfg.public_records(DPU_TABLE_MSIX_TABLE, scope, rows, why), why);
		masked_row = 0;
		foreach (rows[r]) begin
			dpu_msix_table_entry_t	entry;

			entry = dpu_msix_table_entry_t'(rows[r].entry);
			if (entry.msix_data == 'h5001) masked_row = entry.msix_mask === 1'b1;
		end
		check(masked_row, "masked leased message lost its mask in the MSI-X table row");
	endfunction

	initial begin
		string			fields[$] = '{"requester", "intel_pf", "intel_vf", "vport"};
		string			values[$] = '{"1", "1", "-1", "1"};
		int unsigned			pfvf[string];
		dpu_env_cfg				cfg;
		dpu_env_cfg				early;
		dpu_device_snapshot		device;
		dpu_resource_snapshot	resources;
		dpu_bar_map				map;
		int unsigned			global_base;
		int unsigned			local_base;
		string					why;

		for (int unsigned h = 0; h < 2; h++) begin
			foreach (fields[i])
				aip_cmdline_override::set_val($sformatf("dpu.h%0d.pf1.%s", h, fields[i]), values[i]);
			for (int unsigned p = 0; p < 2; p++)
				aip_cmdline_override::set_val($sformatf("dpu.h%0d.pf%0d.msix.msg_data_base", h, p),
					$sformatf("%0d", 'h100 * (2*h + p)));
		end
		aip_cmdline_override::set_val("dpu.msix.msg_addr_base", "0x100000000");
		aip_cmdline_override::set_val("dpu.msix.msg_data_stride", "1");
		// 缺省 pfvf 都是 0：两个 Host 上各有两个拥有消息的 PF 同号，publish 在冻结前拒绝。
		check(!fixture(0, 1, cfg, device, resources, map, why) && (why ==
			"dpu.h0.pf0 and dpu.h0.pf1 share pfvf 0; give each MSI-X Function its DUT pfvf_id (dpu.h0.pf1.pfvf)" ||
			why == "dpu.h0.pf1 and dpu.h0.pf0 share pfvf 0; give each MSI-X Function its DUT pfvf_id (dpu.h0.pf0.pfvf)"),
			{"shared pfvf was not rejected at publish: ", why});
		// pfvf 的顺序与 PF 编号相反，排序必须按参数值。
		pfvf[dpu_function_key_name(pf(0, 0))] = 5;
		pfvf[dpu_function_key_name(pf(0, 1))] = 2;
		pfvf[dpu_function_key_name(pf(1, 0))] = 1;
		pfvf[dpu_function_key_name(pf(1, 1))] = 7;
		for (int unsigned h = 0; h < 2; h++)
			for (int unsigned p = 0; p < 2; p++)
				aip_cmdline_override::set_val($sformatf("dpu.h%0d.pf%0d.pfvf", h, p),
					$sformatf("%0d", pfvf[dpu_function_key_name(pf(h, p))]));
		aip_cmdline_override::set_val("dpu.h0.pf1.first_vf_offset", "3");
		check(fixture(0, 1, cfg, device, resources, map, why), {"publish with distinct pfvf: ", why});
		check(cfg.frozen_functions[dpu_function_key_name(pf(0, 1))].first_vf_offset == 3 &&
			cfg.frozen_functions[dpu_function_key_name(pf(1, 0))].pfvf == 1, "pfvf/first_vf_offset parameters not stored");
		check_lease(cfg, device, resources, 0);
		check_linear(cfg, pfvf);
		check_lease_scope();
		// 平台在 publish 之前（env build）租向量，publish 后同一份快照上的租约接着排；另一份快照的租约被拒绝。
		check(fixture(1, 0, early, device, resources, map, why), why);
		check_lease(early, device, resources, 1);
		check(early.publish(device, resources, map, why), {"publish after leasing: ", why});
		check(early.lease_msix_vectors(device, resources, pf(0, 1), 1, global_base, local_base, why) &&
			global_base == 108, {"lease after publish did not continue: ", why});
		check(!early.lease_msix_vectors(cfg.device_snapshot, cfg.resource_snapshot, pf(0, 1), 1, global_base,
			local_base, why) && why == "MSI-X vector lease belongs to another resource snapshot",
			"lease on another resource snapshot accepted");
		for (int unsigned h = 0; h < 2; h++)
			for (int unsigned p = 0; p < 2; p++)
				aip_cmdline_override::clear($sformatf("dpu.h%0d.pf%0d.pfvf", h, p));
		aip_cmdline_override::clear("dpu.h0.pf1.first_vf_offset");
		check_param("dpu.h0.pf1.pfvf", "1024", 0, "dpu.h0.pf1.pfvf is outside the Intel/VIO field range");
		check_param("dpu.h0.pf0.vf0.pfvf", "3", 1,
			"dpu.h0.pf0.vf0 requires requester, intel_pf, intel_vf and vport together");
		check_param("dpu.h0.pf0.vf0.first_vf_offset", "1", 1, "dpu.h0.pf0.vf0.first_vf_offset is set on the PF only");
		$display("DPU_MSIX_CFG_PASS");
		$finish;
	end
endmodule
