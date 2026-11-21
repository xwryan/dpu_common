// Function L2 身份测试：dpu.hH.pfP[.vfV].mac / .vlan.* 的缺省推导、参数覆盖、取值检查、发布时的 MAC 唯一性与失败原子性；
// 以及 vport 的自动分配与全设备唯一（DUT 的 global Function ID）。
// 两个 Host、各两个 PF、每 PF 一个 VF；用正式 resolver 与 BAR map 发布，不分配 ring、不访问 DUT。
module dpu_function_l2_test;
	import uvm_pkg::*;
	import dpu_resource_pkg::*;
	import aip_core_pkg::*;
	`include "uvm_macros.svh"

	// 只在取值错误用例期间安装：吞掉 PROJECT_CFG 的 UVM_FATAL 并记下最后一条消息。
	class l2_fatal_catcher extends uvm_report_catcher;
		int unsigned	caught;
		string			last;

		function new(string name = "l2_fatal_catcher");
			super.new(name);
		endfunction

		virtual function action_e catch();
			if (get_severity() == UVM_FATAL && get_id() == "PROJECT_CFG") begin
				caught++;
				last = get_message();
				return CAUGHT;
			end
			return THROW;
		endfunction
	endclass

	function automatic void check(input bit	ok, input string	why);
		if (!ok) `uvm_fatal("L2_TEST", why)
	endfunction

	function automatic dpu_function_key_t key(input int unsigned	host, input int unsigned	pf, input int	vf = -1);
		key = '{host_id: host, pf_id: pf, kind: (vf < 0) ? DPU_FUNCTION_PF : DPU_FUNCTION_VF,
				vf_id: (vf < 0) ? 0 : vf};
	endfunction

	// vport = 64*host + 16*pf（PF）或再加 1+vf（VF），全设备唯一；route_all=0 时 Host1 的 VF 不给路由策略。
	function automatic dpu_env_cfg make_cfg(input string	name, input bit	route_all);
		dpu_env_cfg	cfg;

		cfg = new(name);
		cfg.hosts        = 2;
		cfg.pfs_per_host = 2;
		cfg.vfs_per_pf   = 1;
		cfg.reg_target   = "h0.pf0.bar0";
		cfg.load_params();
		foreach (cfg.device_cfg.functions[f]) begin
			dpu_function_key_t		owner;
			dpu_function_policy_t	fp;

			owner = cfg.device_cfg.functions[f].key;
			if (!route_all && owner.host_id == 1 && owner.kind == DPU_FUNCTION_VF) continue;
			fp       = '{key: owner, mode: DPU_HOST_EP, intel_vf: -1, default: 0};
			fp.vport = 64 * owner.host_id + 16 * owner.pf_id + ((owner.kind == DPU_FUNCTION_VF) ? 1 + owner.vf_id : 0);
			cfg.function_policies[dpu_function_key_name(owner)] = fp;
		end
		return cfg;
	endfunction

	function automatic void resolve(
		input dpu_env_cfg				cfg,
		output dpu_device_snapshot		device,
		output dpu_resource_snapshot	resources,
		output dpu_bar_map				map
	);
		dpu_configuration_resolver	resolver;
		dpu_placement_diagnostic	diagnostic;
		string						why;

		resolver = new("resolver");
		check(resolver.resolve(cfg.device_cfg, cfg.placement_cfg, device, resources, diagnostic),
			  {"resolve: ", diagnostic.message});
		map = new("map");
		check(map.initialize(device, 1, why) && map.freeze(why), {"BAR map: ", why});
	endfunction

	function automatic dpu_function_l2_t l2_of(input dpu_env_cfg	cfg, input dpu_function_key_t	k);
		dpu_function_l2_t	l2;

		check(cfg.get_function_l2(k, l2), {"no published L2 for ", dpu_function_key_name(k)});
		return l2;
	endfunction

	// 缺省：有路由策略的 Function 按 Host/vport 推导 MAC；没有路由策略的没有 MAC，
	// 也不参与唯一性检查；PVID 1、优先级 0、trunk 为空。发布前和未知 Function 查不到。
	function automatic void test_defaults();
		dpu_env_cfg				cfg;
		dpu_device_snapshot		device;
		dpu_resource_snapshot	resources;
		dpu_bar_map				map;
		dpu_function_l2_t		l2;
		string					why;

		cfg = make_cfg("defaults", 0);
		check(!cfg.get_function_l2(key(0, 0), l2), "L2 visible before publish");
		resolve(cfg, device, resources, map);
		check(cfg.publish(device, resources, map, why), {"publish: ", why});
		foreach (cfg.device_cfg.functions[f]) begin
			dpu_function_key_t	k;
			string				name;

			k    = cfg.device_cfg.functions[f].key;
			name = dpu_function_key_name(k);
			l2   = l2_of(cfg, k);
			check(l2.pvid == 1 && l2.pri == 0 && l2.trunk.size() == 0 && !l2.mac_given,
				  {name, ": default VLAN must be PVID 1, priority 0, no trunk"});
			if (cfg.function_policies.exists(name))
				check(l2.mac_valid && l2.mac == dpu_default_function_mac(k.host_id, cfg.function_policies[name].vport),
					  $sformatf("%s: derived MAC %s", name, dpu_mac_string(l2.mac)));
			else
				check(!l2.mac_valid && l2.mac == 0, {name, ": a Function without route policy has no MAC"});
		end
		l2 = l2_of(cfg, key(1, 1));
		check(l2.mac == 48'h02_00_00_01_00_50, "h1.pf1 MAC must be 02:00:00:01:00:50 (vport 80)");
		l2 = l2_of(cfg, key(0, 1, 0));
		check(l2.mac == 48'h02_00_00_00_00_11, "h0.pf1.vf0 MAC must be 02:00:00:00:00:11");
		check(!cfg.get_function_l2(key(5, 0), l2), "unknown Function returned an L2 record");
		$display("L2 defaults passed");
	endfunction

	// 参数覆盖：MAC、PVID、优先级、trunk；没有路由策略的 Function 显式给 mac 后也有 MAC。
	function automatic void test_overrides();
		dpu_env_cfg				cfg;
		dpu_device_snapshot		device;
		dpu_resource_snapshot	resources;
		dpu_bar_map				map;
		dpu_function_l2_t		l2;
		string					why;
		string					keys[$] = '{"dpu.h0.pf1.mac", "dpu.h0.pf1.vlan.pvid", "dpu.h0.pf1.vlan.pri",
											"dpu.h0.pf1.vlan.trunk", "dpu.h1.pf1.vf0.mac", "dpu.h0.pf0.vf0.vlan.trunk"};

		aip_cmdline_override::set_val("dpu.h0.pf1.mac", "0x0a0b0c0d0e10");
		aip_cmdline_override::set_val("dpu.h0.pf1.vlan.pvid", "10");
		aip_cmdline_override::set_val("dpu.h0.pf1.vlan.pri", "5");
		aip_cmdline_override::set_val("dpu.h0.pf1.vlan.trunk", "20,30");
		aip_cmdline_override::set_val("dpu.h1.pf1.vf0.mac", "0x020000aabbcc");
		aip_cmdline_override::set_val("dpu.h0.pf0.vf0.vlan.trunk", "4094");
		cfg = make_cfg("overrides", 0);
		foreach (keys[i]) aip_cmdline_override::clear(keys[i]);
		resolve(cfg, device, resources, map);
		check(cfg.publish(device, resources, map, why), {"publish: ", why});
		l2 = l2_of(cfg, key(0, 1));
		check(l2.mac_valid && l2.mac_given && l2.mac == 48'h0a_0b_0c_0d_0e_10 && l2.pvid == 10 && l2.pri == 5 &&
			  l2.trunk.size() == 2 && l2.trunk[0] == 20 && l2.trunk[1] == 30,
			  $sformatf("h0.pf1 overrides: mac=%s pvid=%0d pri=%0d trunk=%p", dpu_mac_string(l2.mac), l2.pvid,
						l2.pri, l2.trunk));
		check(dpu_vlan_member(l2, 10) && dpu_vlan_member(l2, 30) && !dpu_vlan_member(l2, 1),
			  "membership must be PVID plus trunk");
		l2 = l2_of(cfg, key(1, 1, 0));
		check(l2.mac_valid && l2.mac_given && l2.mac == 48'h02_00_00_aa_bb_cc,
			  "explicit MAC on a Function without route policy");
		l2 = l2_of(cfg, key(0, 0, 0));
		check(l2.pvid == 1 && l2.trunk.size() == 1 && l2.trunk[0] == 4094, "h0.pf0.vf0 trunk 4094");
		l2 = l2_of(cfg, key(0, 0));
		check(!l2.mac_given && l2.mac == 48'h02_00_00_00_00_00 && l2.trunk.size() == 0,
			  "a PF override must not leak to other Functions");
		$display("L2 overrides passed");
	endfunction

	// 取值检查（静态函数，与 load_params、publish 共用）。
	function automatic void test_value_checks();
		dpu_function_l2_t	base;
		dpu_function_l2_t	l2;
		string				why;

		base           = dpu_default_function_l2(key(0, 0));
		base.mac_valid = 1;
		base.mac       = 48'h02_00_00_00_00_01;
		check(dpu_env_cfg::check_function_l2(base, why), {"valid L2 rejected: ", why});
		l2 = base; l2.mac = 48'h03_00_00_00_00_01;
		check(!dpu_env_cfg::check_function_l2(l2, why) && uvm_is_match("*unicast*", why), "multicast MAC accepted");
		l2 = base; l2.mac = 48'h01_00_5e_00_00_01;
		check(!dpu_env_cfg::check_function_l2(l2, why), "IPv4 multicast MAC accepted");
		l2 = base; l2.mac = 48'hff_ff_ff_ff_ff_ff;
		check(!dpu_env_cfg::check_function_l2(l2, why), "broadcast MAC accepted");
		l2 = base; l2.mac = '0;
		check(!dpu_env_cfg::check_function_l2(l2, why) && uvm_is_match("*dpu.h0.pf0.mac*", why), "zero MAC accepted");
		l2 = base; l2.mac_valid = 0; l2.mac = '0;
		check(dpu_env_cfg::check_function_l2(l2, why), {"Function without MAC rejected: ", why});
		l2 = base; l2.pvid = 0;
		check(!dpu_env_cfg::check_function_l2(l2, why) && uvm_is_match("*vlan.pvid=0*", why), "PVID 0 accepted");
		l2 = base; l2.pvid = 4095;
		check(!dpu_env_cfg::check_function_l2(l2, why), "PVID 4095 accepted");
		l2 = base; l2.pvid = 4094;
		check(dpu_env_cfg::check_function_l2(l2, why), {"PVID 4094 rejected: ", why});
		l2 = base; l2.pri = 8;
		check(!dpu_env_cfg::check_function_l2(l2, why) && uvm_is_match("*vlan.pri=8*", why), "priority 8 accepted");
		l2 = base; l2.trunk = '{10, 1};
		check(!dpu_env_cfg::check_function_l2(l2, why) && uvm_is_match("*repeats the PVID*", why),
			  "trunk containing the PVID accepted");
		l2 = base; l2.trunk = '{10, 20, 10};
		check(!dpu_env_cfg::check_function_l2(l2, why) && uvm_is_match("*VLAN 10 twice*", why),
			  "duplicate trunk entry accepted");
		l2 = base; l2.trunk = '{0};
		check(!dpu_env_cfg::check_function_l2(l2, why) && uvm_is_match("*vlan.trunk*=0 is outside*", why),
			  "trunk VLAN 0 accepted");
		l2 = base; l2.trunk = '{2, 4095};
		check(!dpu_env_cfg::check_function_l2(l2, why) && uvm_is_match("*vlan.trunk*=4095 is outside*", why),
			  "trunk VLAN 4095 accepted");
		l2 = base; l2.trunk = '{4094, 2};
		check(dpu_env_cfg::check_function_l2(l2, why), {"valid trunk rejected: ", why});
		$display("L2 value checks passed");
	endfunction

	// 唯一性在全部 Host 上检查：PF 与 VF 显式同 MAC、显式 MAC 撞上别的 Function 的推导值、同 Host 或跨 Host 的同一 vport
	// 都拒绝发布；失败的重新发布保留旧发布值。
	function automatic void test_duplicates();
		dpu_env_cfg				cfg;
		dpu_device_snapshot		device;
		dpu_resource_snapshot	resources;
		dpu_bar_map				map;
		dpu_function_l2_t		l2;
		string					why;
		string					pf;
		string					vf;

		cfg = make_cfg("dup_pf_vf", 1);
		pf  = dpu_function_key_name(key(0, 0));
		vf  = dpu_function_key_name(key(1, 1, 0));
		cfg.function_l2[pf].mac       = 48'h02_00_00_12_34_56;
		cfg.function_l2[pf].mac_given = 1;
		cfg.function_l2[pf].mac_valid = 1;
		cfg.function_l2[vf]           = cfg.function_l2[pf];
		cfg.function_l2[vf].key       = key(1, 1, 0);
		resolve(cfg, device, resources, map);
		check(!cfg.publish(device, resources, map, why) && uvm_is_match("*share MAC 02:00:00:12:34:56*", why) &&
			  uvm_is_match("*dpu.h1.pf1.vf0*", why), {"PF/VF duplicate MAC published: ", why});

		cfg = make_cfg("dup_vport", 1);
		cfg.function_policies[dpu_function_key_name(key(0, 1))].vport = 0;
		resolve(cfg, device, resources, map);
		check(!cfg.publish(device, resources, map, why) &&
			  uvm_is_match("dpu.h0.pf0 and dpu.h0.pf1 share vport 0; a vport is device-wide*", why),
			  {"same-Host vport duplicate published: ", why});

		cfg = make_cfg("dup_vport_hosts", 1);
		cfg.function_policies[dpu_function_key_name(key(1, 0))].vport = 0;
		resolve(cfg, device, resources, map);
		check(!cfg.publish(device, resources, map, why) &&
			  uvm_is_match("dpu.h0.pf0 and dpu.h1.pf0 share vport 0;*drop the explicit dpu.h1.pf0.vport*", why),
			  {"cross-Host vport duplicate published: ", why});

		cfg = make_cfg("dup_derived", 1);
		pf  = dpu_function_key_name(key(1, 0));
		cfg.function_l2[pf].mac       = dpu_default_function_mac(0, 17);
		cfg.function_l2[pf].mac_given = 1;
		cfg.function_l2[pf].mac_valid = 1;
		resolve(cfg, device, resources, map);
		check(!cfg.publish(device, resources, map, why) && uvm_is_match("*dpu.h0.pf1.vf0*dpu.h1.pf0*", why),
			  {"explicit MAC equal to a derived MAC published: ", why});

		// 先成功发布，再把 h0.pf1 改成与 h0.pf0 同 MAC：重新发布失败，发布值不变。
		cfg = make_cfg("atomic", 1);
		resolve(cfg, device, resources, map);
		check(cfg.publish(device, resources, map, why), {"publish: ", why});
		pf = dpu_function_key_name(key(0, 1));
		cfg.function_l2[pf].mac       = dpu_default_function_mac(0, 0);
		cfg.function_l2[pf].mac_given = 1;
		cfg.function_l2[pf].mac_valid = 1;
		check(!cfg.publish(device, resources, map, why), "duplicate MAC accepted on republish");
		l2 = l2_of(cfg, key(0, 1));
		check(l2.mac == dpu_default_function_mac(0, 16) && !l2.mac_given, "failed publish replaced the published L2");
		// 同一份 cfg 再把 h1.pf1 的 vport 改成 h0.pf1 的 16：重新发布失败，发布的路由策略与 L2 不变。
		cfg.function_l2[pf].mac_given = 0;
		cfg.function_l2[pf].mac_valid = 0;
		cfg.function_policies[dpu_function_key_name(key(1, 1))].vport = 16;
		check(!cfg.publish(device, resources, map, why) && uvm_is_match("*share vport 16*", why),
			  {"duplicate vport accepted on republish: ", why});
		l2 = l2_of(cfg, key(1, 1));
		check(cfg.frozen_functions[dpu_function_key_name(key(1, 1))].vport == 80 &&
			  l2.mac == dpu_default_function_mac(1, 80), "failed publish replaced the published vport");
		$display("L2 duplicate checks passed");
	endfunction

	function automatic int unsigned vport_of(input dpu_env_cfg	cfg, input dpu_function_key_t	k);
		check(cfg.function_policies.exists(dpu_function_key_name(k)), {"no route policy for ", dpu_function_key_name(k)});
		return cfg.function_policies[dpu_function_key_name(k)].vport;
	endfunction

	function automatic int unsigned bdf_of(input dpu_env_cfg	cfg, input dpu_function_key_t	k);
		check(cfg.function_policies.exists(dpu_function_key_name(k)), {"no route policy for ", dpu_function_key_name(k)});
		return cfg.function_policies[dpu_function_key_name(k)].bdf_index;
	endfunction

	// 只经参数（load_params）建路由：两个 Host、每 Host pfs 个 PF、无 VF（各 Host 的 PF0 有隐式路由）。
	function automatic dpu_env_cfg param_cfg(input string	name, input int unsigned	pfs);
		dpu_env_cfg	cfg;

		cfg = new(name);
		cfg.hosts        = 2;
		cfg.pfs_per_host = pfs;
		cfg.vfs_per_pf   = 0;
		cfg.reg_target   = "h0.pf0.bar0";
		cfg.load_params();
		return cfg;
	endfunction

	// vport 自动分配：隐式 PF0 路由与只给 requester/intel_pf/intel_vf 的路由按 Function 顺序取显式值和先前自动值都没占用的
	// 最小号；bdf_index 不给时等于最终的 vport；显式值在 Host 之间重复时 publish 拒绝；只给 vport 不给路由在 load 时 fatal。
	function automatic void test_auto_vport();
		dpu_env_cfg				cfg;
		dpu_device_snapshot		device;
		dpu_resource_snapshot	resources;
		dpu_bar_map				map;
		dpu_function_l2_t		l2;
		l2_fatal_catcher		catcher;
		string					why;
		string					keys[$];
		string					vals[$];

		cfg = param_cfg("auto_pf0", 1);
		check(vport_of(cfg, key(0, 0)) == 0 && vport_of(cfg, key(1, 0)) == 1 && bdf_of(cfg, key(1, 0)) == 1,
			  $sformatf("implicit PF0 routes: vports %0d/%0d bdf_index %0d, expected 0/1 and 1", vport_of(cfg, key(0, 0)),
						vport_of(cfg, key(1, 0)), bdf_of(cfg, key(1, 0))));
		resolve(cfg, device, resources, map);
		check(cfg.publish(device, resources, map, why), {"publish implicit PF0 routes: ", why});
		l2 = l2_of(cfg, key(1, 0));
		check(l2.mac == 48'h02_00_00_01_00_01, $sformatf("h1.pf0 default MAC %s, expected 02:00:00:01:00:01",
														 dpu_mac_string(l2.mac)));

		// h0.pf0 显式 1、h1.pf1 显式 0；h0.pf1、h1.pf0 自动取 2、3。h1.pf0 显式给的 bdf_index 7 不跟 vport。
		keys = '{"dpu.h0.pf0.vport", "dpu.h0.pf1.requester", "dpu.h0.pf1.intel_pf", "dpu.h0.pf1.intel_vf",
				 "dpu.h1.pf1.requester", "dpu.h1.pf1.intel_pf", "dpu.h1.pf1.intel_vf", "dpu.h1.pf1.vport",
				 "dpu.h1.pf0.bdf_index"};
		vals = '{"1", "1", "1", "-1", "3", "1", "-1", "0", "7"};
		foreach (keys[i]) aip_cmdline_override::set_val(keys[i], vals[i]);
		cfg = param_cfg("auto_mix", 2);
		foreach (keys[i]) aip_cmdline_override::clear(keys[i]);
		check(vport_of(cfg, key(0, 0)) == 1 && vport_of(cfg, key(0, 1)) == 2 && vport_of(cfg, key(1, 0)) == 3 &&
			  vport_of(cfg, key(1, 1)) == 0,
			  $sformatf("explicit/auto mix: h0.pf0=%0d h0.pf1=%0d h1.pf0=%0d h1.pf1=%0d, expected 1/2/3/0",
						vport_of(cfg, key(0, 0)), vport_of(cfg, key(0, 1)), vport_of(cfg, key(1, 0)),
						vport_of(cfg, key(1, 1))));
		check(bdf_of(cfg, key(0, 0)) == 1 && bdf_of(cfg, key(0, 1)) == 2 && bdf_of(cfg, key(1, 0)) == 7 &&
			  bdf_of(cfg, key(1, 1)) == 0, "bdf_index must follow the final vport unless it is given");
		resolve(cfg, device, resources, map);
		check(cfg.publish(device, resources, map, why), {"publish explicit/auto mix: ", why});

		// 显式值在 Host 之间重复：load 不报错，publish 拒绝并指出两个 Function。
		aip_cmdline_override::set_val("dpu.h0.pf0.vport", "5");
		aip_cmdline_override::set_val("dpu.h1.pf0.vport", "5");
		cfg = param_cfg("auto_dup", 1);
		aip_cmdline_override::clear("dpu.h0.pf0.vport");
		aip_cmdline_override::clear("dpu.h1.pf0.vport");
		resolve(cfg, device, resources, map);
		check(!cfg.publish(device, resources, map, why) &&
			  uvm_is_match("dpu.h0.pf0 and dpu.h1.pf0 share vport 5; a vport is device-wide*", why),
			  {"explicit duplicate vport across Hosts published: ", why});

		// 只给 vport、不给 requester/intel_pf/intel_vf：load 时 fatal。
		catcher = new("route_fatal");
		uvm_report_cb::add(null, catcher);
		aip_cmdline_override::set_val("dpu.h0.pf1.vport", "3");
		cfg = param_cfg("vport_only", 2);
		aip_cmdline_override::clear("dpu.h0.pf1.vport");
		uvm_report_cb::delete(null, catcher);
		check(catcher.caught == 1 && catcher.last == {"dpu.h0.pf1 ", "requires requester, intel_pf and intel_vf together (vport is optional and assigned automatically when omitted)"},
			  $sformatf("vport without route: caught=%0d %s", catcher.caught, catcher.last));
		$display("vport auto assignment passed");
	endfunction

	// 参数取值错误在 load_params 时 fatal（用 catcher 吞掉后核对消息）。
	function automatic void test_param_errors();
		l2_fatal_catcher	catcher;
		dpu_env_cfg			cfg;

		catcher = new("l2_fatal");
		uvm_report_cb::add(null, catcher);
		aip_cmdline_override::set_val("dpu.h0.pf0.vlan.trunk", "1");
		cfg = make_cfg("bad_trunk", 0);
		aip_cmdline_override::clear("dpu.h0.pf0.vlan.trunk");
		check(catcher.caught == 1 && uvm_is_match("*dpu.h0.pf0.vlan.trunk*repeats the PVID*", catcher.last),
			  $sformatf("trunk containing the PVID: caught=%0d %s", catcher.caught, catcher.last));
		aip_cmdline_override::set_val("dpu.h1.pf0.vf0.mac", "0x010000000001");
		cfg = make_cfg("bad_mac", 0);
		aip_cmdline_override::clear("dpu.h1.pf0.vf0.mac");
		check(catcher.caught == 2 && uvm_is_match("*dpu.h1.pf0.vf0.mac=01:00:00:00:00:01*unicast*", catcher.last),
			  $sformatf("multicast MAC: caught=%0d %s", catcher.caught, catcher.last));
		aip_cmdline_override::set_val("dpu.h0.pf1.vlan.pvid", "4095");
		cfg = make_cfg("bad_pvid", 0);
		aip_cmdline_override::clear("dpu.h0.pf1.vlan.pvid");
		check(catcher.caught == 3 && uvm_is_match("*dpu.h0.pf1.vlan.pvid=4095*", catcher.last),
			  $sformatf("PVID 4095: caught=%0d %s", catcher.caught, catcher.last));
		uvm_report_cb::delete(null, catcher);
		$display("L2 parameter errors passed");
	endfunction

	initial begin
		test_defaults();
		test_overrides();
		test_value_checks();
		test_duplicates();
		test_auto_vport();
		test_param_errors();
		$display("DPU_FUNCTION_L2_PASS");
		$finish;
	end
endmodule
