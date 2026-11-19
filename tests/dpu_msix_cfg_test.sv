// dpu_env_cfg 的 MSI-X 聚焦测试：真实 resolver、BAR map 与 publish；不分配 ring、不访问 DUT。
// 向量租约接在 resolver 记录的向量块和已登记消息之后，依次接续，越界的租约不占用向量；publish 前后都可租。
module dpu_msix_cfg_test;
	import uvm_pkg::*;
	import dpu_resource_pkg::*;
	import aip_core_pkg::*;
	`include "uvm_macros.svh"

	function automatic void check(input bit	ok, input string	why);
		if (!ok) `uvm_fatal("MSIX_TEST", why)
	endfunction

	function automatic dpu_function_key_t pf(input int unsigned	host, input int unsigned	pf_id);
		return '{host_id: host, pf_id: pf_id, kind: DPU_FUNCTION_PF, vf_id: 0};
	endfunction

	// 两个 Host、各两个 PF，每个 PF 一个启用 MSI-X 的 VIO service（qpair 数各不相同），PF1 的路由由参数给出。
	// 消息模板按 Function 取不同 data 基址，同一 Host 的消息互不混淆；authored=1 时另登记一条块外的显式消息。
	// publish_now=1 时返回 publish 的结果，否则只解析、冻结快照与 BAR map。
	function automatic bit fixture(
		input bit					authored,
		input bit					publish_now,
		output dpu_env_cfg			cfg,
		output dpu_device_snapshot	device,
		output dpu_resource_snapshot	resources,
		output dpu_bar_map			map,
		output string				why
	);
		dpu_configuration_resolver	resolver;
		dpu_placement_diagnostic	diagnostic;
		dpu_msix_message_t			message;

		cfg                   = new("msix_cfg");
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
			service.msix_enable = 1;
			service.qpairs      = 1 + f;
			cfg.add_vio_service(service);
		end
		if (authored) begin
			message = '{owner: pf(1, 0), local_vector: 40, global_vector: 100, address: 64'h1_0000_1000,
				data: 32'habc, masked: 0};
			cfg.messages.push_back(message);
		end
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

	initial begin
		string			fields[$] = '{"requester", "intel_pf", "intel_vf", "vport"};
		string			values[$] = '{"1", "1", "-1", "1"};
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
		check(fixture(0, 1, cfg, device, resources, map, why), {"publish: ", why});
		check_lease(cfg, device, resources, 0);
		// 平台在 publish 之前（env build）租向量，publish 后同一份快照上的租约接着排；另一份快照的租约被拒绝。
		check(fixture(1, 0, early, device, resources, map, why), why);
		check_lease(early, device, resources, 1);
		check(early.publish(device, resources, map, why), {"publish after leasing: ", why});
		check(early.lease_msix_vectors(device, resources, pf(0, 1), 1, global_base, local_base, why) &&
			global_base == 108, {"lease after publish did not continue: ", why});
		check(!early.lease_msix_vectors(cfg.device_snapshot, cfg.resource_snapshot, pf(0, 1), 1, global_base,
			local_base, why) && why == "MSI-X vector lease belongs to another resource snapshot",
			"lease on another resource snapshot accepted");
		$display("DPU_MSIX_CFG_PASS");
		$finish;
	end
endmodule
