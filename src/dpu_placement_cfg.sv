// VIO 放置 authoring 配置：候选过滤、设备约束、qpair 覆盖、放置请求与诊断。
`ifndef DPU_PLACEMENT_CFG_SV
`define DPU_PLACEMENT_CFG_SV

// function key 集合（候选/固定设备）为值语义，不建立 PF/VF 或绑定资源；显式给出的集合是一次完整声明
// （支持 AIP size/each/索引/compact，新条目缺省 h0/pf0/PF/vf0），无参数时保留原集合，键与拓扑引用由 load_params/normalizer 校验。
`aip_struct_type_begin(dpu_function_key_t)
    `aip_field_int(int unsigned, host_id, 0)
    `aip_field_int(int unsigned, pf_id, 0)
    `aip_field_enum(dpu_function_kind_e, kind, DPU_FUNCTION_PF)
    `aip_field_int(int unsigned, vf_id, 0)
`aip_struct_type_end(dpu_function_key_t)

class dpu_vio_candidate_filter extends uvm_object;
    `uvm_object_utils(dpu_vio_candidate_filter)

    int unsigned host_ids[$];
    dpu_function_key_t parent_pf_keys[$];
    int unsigned vf_ids[$];
    dpu_function_key_t function_keys[$];

    function new(string name = "dpu_vio_candidate_filter");
        super.new(name);
    endfunction

    function void copy_from(input dpu_vio_candidate_filter rhs);
        host_ids = rhs.host_ids;
        parent_pf_keys = rhs.parent_pf_keys;
        vf_ids = rhs.vf_ids;
        function_keys = rhs.function_keys;
    endfunction

    virtual function void do_copy(uvm_object rhs);
        dpu_vio_candidate_filter typed_rhs;

        super.do_copy(rhs);
        if (!$cast(typed_rhs, rhs)) begin
            `uvm_error("DPU_CFG_COPY", "candidate filter copy received incompatible object")
            return;
        end
        copy_from(typed_rhs);
    endfunction

    function void load_params(string	path = "dpu");
        begin
            bit	present;
            int unsigned	host_ids[$];
            present = aip_cmdline_query::present(path, "host_ids", 1);
            if (present) begin
                `aip_int_queue(path, int unsigned, host_ids, 0)
                foreach (host_ids[index]) begin
                    if (host_ids[index] >= DPU_MAX_HOSTS)
                        $fatal(1, "DPU_PARAMS: %s.host_ids[%0d] exceeds legal ID capacity", path, index);
                end
                this.host_ids = host_ids;
            end
        end
        begin
            bit	present;
            int unsigned	vf_ids[$];
            present = aip_cmdline_query::present(path, "vf_ids", 1);
            if (present) begin
                `aip_int_queue(path, int unsigned, vf_ids, 0)
                foreach (vf_ids[index]) begin
                    if (vf_ids[index] >= DPU_MAX_VFS_PER_PF)
                        $fatal(1, "DPU_PARAMS: %s.vf_ids[%0d] exceeds legal ID capacity", path, index);
                end
                this.vf_ids = vf_ids;
            end
        end
        begin
            bit	present;
            dpu_function_key_t	parent_pfs[$];
            present = aip_cmdline_query::present(path, "parent_pfs", 1);
            if (present) begin
                `aip_struct_queue_apply(({path, ".parent_pfs"}), dpu_function_key_t, parent_pfs)
                foreach (parent_pfs[index]) begin
                    if (parent_pfs[index].host_id >= DPU_MAX_HOSTS ||
                        parent_pfs[index].pf_id >= DPU_MAX_PFS_PER_HOST ||
                        parent_pfs[index].vf_id >= DPU_MAX_VFS_PER_PF ||
                        (parent_pfs[index].kind == DPU_FUNCTION_PF && parent_pfs[index].vf_id != 0) ||
                        parent_pfs[index].kind != DPU_FUNCTION_PF)
                        $fatal(1, "DPU_PARAMS: %s.parent_pfs[%0d] contains an invalid function key", path, index);
                end
                this.parent_pf_keys = parent_pfs;
            end
        end
        begin
            bit	present;
            dpu_function_key_t	functions[$];
            present = aip_cmdline_query::present(path, "functions", 1);
            if (present) begin
                `aip_struct_queue_apply(({path, ".functions"}), dpu_function_key_t, functions)
                foreach (functions[index]) begin
                    if (functions[index].host_id >= DPU_MAX_HOSTS ||
                        functions[index].pf_id >= DPU_MAX_PFS_PER_HOST ||
                        functions[index].vf_id >= DPU_MAX_VFS_PER_PF ||
                        (functions[index].kind == DPU_FUNCTION_PF && functions[index].vf_id != 0))
                        $fatal(1, "DPU_PARAMS: %s.functions[%0d] contains an invalid function key", path, index);
                end
                this.function_keys = functions;
            end
        end
    endfunction

endclass : dpu_vio_candidate_filter


class dpu_vio_device_constraint extends uvm_object;
    `uvm_object_utils(dpu_vio_device_constraint)

    dpu_function_key_t function_key;
    dpu_count_constraint_mode_e mode;
    int unsigned qpair_count;

    function new(string name = "dpu_vio_device_constraint");
        super.new(name);
        mode = DPU_COUNT_EXACT;
        qpair_count = 0;
    endfunction

    function void copy_from(input dpu_vio_device_constraint rhs);
        function_key = rhs.function_key;
        mode = rhs.mode;
        qpair_count = rhs.qpair_count;
    endfunction

    virtual function void do_copy(uvm_object rhs);
        dpu_vio_device_constraint typed_rhs;

        super.do_copy(rhs);
        if (!$cast(typed_rhs, rhs)) begin
            `uvm_error("DPU_CFG_COPY", "device constraint copy received incompatible object")
            return;
        end
        copy_from(typed_rhs);
    endfunction

    function void load_params(string	path = "dpu.device");
        begin
            int unsigned	host;
            `aip_uint(path, int unsigned, host, this.function_key.host_id)
            this.function_key.host_id = host;
        end
        begin
            int unsigned	pf;
            `aip_uint(path, int unsigned, pf, this.function_key.pf_id)
            this.function_key.pf_id = pf;
        end
        begin
            dpu_function_kind_e	kind;
            `aip_enum(path, dpu_function_kind_e, kind, this.function_key.kind)
            this.function_key.kind = kind;
        end
        begin
            int unsigned	vf;
            `aip_uint(path, int unsigned, vf, this.function_key.vf_id)
            this.function_key.vf_id = vf;
        end
        begin
            dpu_count_constraint_mode_e	mode;
            `aip_enum(path, dpu_count_constraint_mode_e, mode, this.mode)
            this.mode = mode;
        end
        begin
            int unsigned	qpairs;
            `aip_uint(path, int unsigned, qpairs, this.qpair_count)
            this.qpair_count = qpairs;
        end
    endfunction

endclass : dpu_vio_device_constraint


class dpu_vio_qpair_override extends uvm_object;
    `uvm_object_utils(dpu_vio_qpair_override)

    int unsigned request_pair_index;
    dpu_assignment_mode_e owner_mode;
    dpu_function_key_t requested_owner;
    dpu_assignment_mode_e local_mode;
    int unsigned requested_local_pair_id;
    dpu_assignment_mode_e global_mode;
    int unsigned requested_global_qpair_id;

    function new(string name = "dpu_vio_qpair_override");
        super.new(name);
        request_pair_index = 0;
        owner_mode = DPU_ASSIGN_AUTO;
        local_mode = DPU_ASSIGN_AUTO;
        global_mode = DPU_ASSIGN_AUTO;
        requested_local_pair_id = 0;
        requested_global_qpair_id = 0;
    endfunction

    function void copy_from(input dpu_vio_qpair_override rhs);
        request_pair_index = rhs.request_pair_index;
        owner_mode = rhs.owner_mode;
        requested_owner = rhs.requested_owner;
        local_mode = rhs.local_mode;
        requested_local_pair_id = rhs.requested_local_pair_id;
        global_mode = rhs.global_mode;
        requested_global_qpair_id = rhs.requested_global_qpair_id;
    endfunction

    virtual function void do_copy(uvm_object rhs);
        dpu_vio_qpair_override typed_rhs;

        super.do_copy(rhs);
        if (!$cast(typed_rhs, rhs)) begin
            `uvm_error("DPU_CFG_COPY", "qpair override copy received incompatible object")
            return;
        end
        copy_from(typed_rhs);
    endfunction

    function void load_params(string	path = "dpu.pair");
        begin
            int unsigned	index;
            `aip_uint(path, int unsigned, index, this.request_pair_index)
            this.request_pair_index = index;
        end
        begin
            dpu_assignment_mode_e	owner_mode;
            `aip_enum(path, dpu_assignment_mode_e, owner_mode, this.owner_mode)
            this.owner_mode = owner_mode;
        end
        begin
            int unsigned	owner_host;
            `aip_uint(path, int unsigned, owner_host, this.requested_owner.host_id)
            this.requested_owner.host_id = owner_host;
        end
        begin
            int unsigned	owner_pf;
            `aip_uint(path, int unsigned, owner_pf, this.requested_owner.pf_id)
            this.requested_owner.pf_id = owner_pf;
        end
        begin
            dpu_function_kind_e	owner_kind;
            `aip_enum(path, dpu_function_kind_e, owner_kind, this.requested_owner.kind)
            this.requested_owner.kind = owner_kind;
        end
        begin
            int unsigned	owner_vf;
            `aip_uint(path, int unsigned, owner_vf, this.requested_owner.vf_id)
            this.requested_owner.vf_id = owner_vf;
        end
        begin
            dpu_assignment_mode_e	local_mode;
            `aip_enum(path, dpu_assignment_mode_e, local_mode, this.local_mode)
            this.local_mode = local_mode;
        end
        begin
            int unsigned	local_id;
            `aip_uint(path, int unsigned, local_id, this.requested_local_pair_id)
            this.requested_local_pair_id = local_id;
        end
        begin
            dpu_assignment_mode_e	global_mode;
            `aip_enum(path, dpu_assignment_mode_e, global_mode, this.global_mode)
            this.global_mode = global_mode;
        end
        begin
            int unsigned	global_id;
            `aip_uint(path, int unsigned, global_id, this.requested_global_qpair_id)
            this.requested_global_qpair_id = global_id;
        end
    endfunction

endclass : dpu_vio_qpair_override


class dpu_vio_placement_request extends uvm_object;
    `uvm_object_utils(dpu_vio_placement_request)

    int unsigned request_id;
    int unsigned service_instance_id;
    int unsigned total_qpairs;
    // LAN MSI-X vectors requested for this function: 0 keeps the driver default (one per qpair in this
    // model); a smaller value models the real driver's min(online_cpus, rxq) sharing policy.
    int unsigned lan_msix_vectors;
    int unsigned seed;
    dpu_vio_candidate_kind_e candidate_kind;
    dpu_vio_device_policy_e device_policy;
    dpu_placement_order_e ordering;
    dpu_vio_candidate_filter candidate_filter;
    dpu_function_key_t fixed_devices[$];
    dpu_vio_device_constraint device_constraints[$];
    dpu_vio_qpair_override qpair_overrides[$];

    function new(string name = "dpu_vio_placement_request");
        super.new(name);
        request_id = 0;
        service_instance_id = 0;
        total_qpairs = 0;
        lan_msix_vectors = 0;
        seed = 0;
        candidate_kind = DPU_VIO_CANDIDATE_PF_AND_VF;
        device_policy = DPU_VIO_DEVICE_AUTO_MINIMUM;
        ordering = DPU_PLACEMENT_CANONICAL;
        candidate_filter = dpu_vio_candidate_filter::type_id::create(
            {name, "_candidate_filter"});
    endfunction

    function void copy_from(input dpu_vio_placement_request rhs);
        dpu_vio_device_constraint constraint_copy;
        dpu_vio_qpair_override override_copy;

        request_id = rhs.request_id;
        service_instance_id = rhs.service_instance_id;
        total_qpairs = rhs.total_qpairs;
        lan_msix_vectors = rhs.lan_msix_vectors;
        seed = rhs.seed;
        candidate_kind = rhs.candidate_kind;
        device_policy = rhs.device_policy;
        ordering = rhs.ordering;
        fixed_devices = rhs.fixed_devices;
        if (rhs.candidate_filter == null) begin
            candidate_filter = null;
        end else begin
            candidate_filter = dpu_vio_candidate_filter::type_id::create(
                {get_name(), "_candidate_filter"});
            candidate_filter.copy_from(rhs.candidate_filter);
        end
        device_constraints.delete();
        foreach (rhs.device_constraints[index]) begin
            if (rhs.device_constraints[index] == null) begin
                device_constraints.push_back(null);
            end else begin
                constraint_copy = dpu_vio_device_constraint::type_id::create(
                    $sformatf("%s_constraint_%0d", get_name(), index));
                constraint_copy.copy_from(rhs.device_constraints[index]);
                device_constraints.push_back(constraint_copy);
            end
        end
        qpair_overrides.delete();
        foreach (rhs.qpair_overrides[index]) begin
            if (rhs.qpair_overrides[index] == null) begin
                qpair_overrides.push_back(null);
            end else begin
                override_copy = dpu_vio_qpair_override::type_id::create(
                    $sformatf("%s_override_%0d", get_name(), index));
                override_copy.copy_from(rhs.qpair_overrides[index]);
                qpair_overrides.push_back(override_copy);
            end
        end
    endfunction

    virtual function void do_copy(uvm_object rhs);
        dpu_vio_placement_request typed_rhs;

        super.do_copy(rhs);
        if (!$cast(typed_rhs, rhs)) begin
            `uvm_error("DPU_CFG_COPY", "placement request copy received incompatible object")
            return;
        end
        copy_from(typed_rhs);
    endfunction

    function void load_params(string	path = "dpu");
        begin
            int unsigned	qpairs;
            `aip_uint(path, int unsigned, qpairs, this.total_qpairs)
            this.total_qpairs = qpairs;
        end
        begin
            int unsigned	lan_msix;
            `aip_uint(path, int unsigned, lan_msix, this.lan_msix_vectors)
            this.lan_msix_vectors = lan_msix;
        end
        begin
            int unsigned	placement_seed;
            `aip_uint(path, int unsigned, placement_seed, this.seed)
            this.seed = placement_seed;
        end
        begin
            dpu_vio_candidate_kind_e	candidate_kind;
            `aip_enum(path, dpu_vio_candidate_kind_e, candidate_kind, this.candidate_kind)
            this.candidate_kind = candidate_kind;
        end
        begin
            dpu_vio_device_policy_e	device_policy;
            `aip_enum(path, dpu_vio_device_policy_e, device_policy, this.device_policy)
            this.device_policy = device_policy;
        end
        begin
            dpu_placement_order_e	ordering;
            `aip_enum(path, dpu_placement_order_e, ordering, this.ordering)
            this.ordering = ordering;
        end
        begin
            bit	present;
            dpu_function_key_t	fixed_devices[$];
            present = aip_cmdline_query::present(path, "fixed_devices", 1);
            if (present) begin
                `aip_struct_queue_apply(({path, ".fixed_devices"}), dpu_function_key_t, fixed_devices)
                foreach (fixed_devices[index]) begin
                    if (fixed_devices[index].host_id >= DPU_MAX_HOSTS ||
                        fixed_devices[index].pf_id >= DPU_MAX_PFS_PER_HOST ||
                        fixed_devices[index].vf_id >= DPU_MAX_VFS_PER_PF ||
                        (fixed_devices[index].kind == DPU_FUNCTION_PF && fixed_devices[index].vf_id != 0))
                        $fatal(1, "DPU_PARAMS: %s.fixed_devices[%0d] contains an invalid function key", path, index);
                end
                this.fixed_devices = fixed_devices;
            end
        end
        if (candidate_filter != null) candidate_filter.load_params(path);
        // 复杂的逐设备约束/逐 qpair 覆盖只加载既有对象，不通过数量参数创建它们。
        foreach (device_constraints[index]) begin
            if (device_constraints[index] != null)
                device_constraints[index].load_params($sformatf("%s.device%0d", path, index));
        end
        foreach (qpair_overrides[index]) begin
            if (qpair_overrides[index] != null)
                qpair_overrides[index].load_params($sformatf("%s.pair%0d", path, index));
        end
    endfunction

endclass : dpu_vio_placement_request


class dpu_resource_placement_cfg extends uvm_object;
    `uvm_object_utils(dpu_resource_placement_cfg)

    dpu_resource_pool_config_t profiles[$];
    dpu_vio_placement_request vio_requests[$];
    int unsigned reserved_global_qpair_ids[$];
    dpu_global_id_range_t reserved_global_qpair_ranges[$];

    function new(string name = "dpu_resource_placement_cfg");
        super.new(name);
    endfunction

    function void copy_from(input dpu_resource_placement_cfg rhs);
        dpu_vio_placement_request request_copy;

        profiles = rhs.profiles;
        reserved_global_qpair_ids = rhs.reserved_global_qpair_ids;
        reserved_global_qpair_ranges = rhs.reserved_global_qpair_ranges;
        vio_requests.delete();
        foreach (rhs.vio_requests[index]) begin
            if (rhs.vio_requests[index] == null) begin
                vio_requests.push_back(null);
            end else begin
                request_copy = dpu_vio_placement_request::type_id::create(
                    $sformatf("%s_request_%0d", get_name(), index));
                request_copy.copy_from(rhs.vio_requests[index]);
                vio_requests.push_back(request_copy);
            end
        end
    endfunction

    virtual function void do_copy(uvm_object rhs);
        dpu_resource_placement_cfg typed_rhs;

        super.do_copy(rhs);
        if (!$cast(typed_rhs, rhs)) begin
            `uvm_error("DPU_CFG_COPY", "placement config copy received incompatible object")
            return;
        end
        copy_from(typed_rhs);
    endfunction

    function void load_params(string	path = "dpu");
        begin
            bit	present;
            int unsigned	reserved_qpairs[$];
            present = aip_cmdline_query::present(path, "reserved_qpairs", 1);
            if (present) begin
                `aip_int_queue(path, int unsigned, reserved_qpairs, 0)
                foreach (reserved_qpairs[index]) begin
                    if (reserved_qpairs[index] >= DPU_MAX_VIO_GLOBAL_QPAIRS)
                        $fatal(1, "DPU_PARAMS: %s.reserved_qpairs[%0d] exceeds legal ID capacity", path, index);
                end
                this.reserved_global_qpair_ids = reserved_qpairs;
            end
        end
        foreach (profiles[index]) begin
            if (profiles[index].name == "virtio.qpair") begin
                int unsigned	qpair_capacity;
                int unsigned	qpair_per_func;
                `aip_uint(path, int unsigned, qpair_capacity, profiles[index].capacity)
                `aip_uint(path, int unsigned, qpair_per_func, profiles[index].max_per_function)
                profiles[index].capacity = qpair_capacity;
                profiles[index].max_per_function = qpair_per_func;
            end else begin
                string	pool_path;
                int unsigned	capacity;
                int unsigned	max_per_function;
                pool_path = $sformatf("%s.pool%0d", path, index);
                `aip_uint(pool_path, int unsigned, capacity, profiles[index].capacity)
                `aip_uint(pool_path, int unsigned, max_per_function, profiles[index].max_per_function)
                profiles[index].capacity = capacity;
                profiles[index].max_per_function = max_per_function;
            end
        end
        // 单 request 使用顶层短名；多 request 各有独立作用域，不重复消费全局随机参数。
        foreach (vio_requests[index]) begin
            if (vio_requests[index] != null)
                vio_requests[index].load_params(vio_requests.size() == 1 ? path :
                                               $sformatf("%s.request%0d", path, index));
        end
    endfunction

endclass : dpu_resource_placement_cfg


class dpu_placement_diagnostic extends uvm_object;
    `uvm_object_utils(dpu_placement_diagnostic)

    dpu_placement_stage_e stage;
    dpu_placement_error_e error_code;
    bit has_request_id;
    bit has_function_key;
    bit has_service_key;
    bit has_pair_index;
    int unsigned request_id;
    int unsigned request_pair_index;
    dpu_function_key_t function_key;
    dpu_service_key_t service_key;
    string message;

    function new(string name = "dpu_placement_diagnostic");
        super.new(name);
        clear();
    endfunction

    function void clear();
        stage = DPU_PLACE_STAGE_NONE;
        error_code = DPU_PLACE_ERR_NONE;
        has_request_id = 0;
        has_function_key = 0;
        has_service_key = 0;
        has_pair_index = 0;
        request_id = 0;
        request_pair_index = 0;
        function_key.host_id = 0;
        function_key.pf_id = 0;
        function_key.kind = DPU_FUNCTION_PF;
        function_key.vf_id = 0;
        service_key.function_key.host_id = 0;
        service_key.function_key.pf_id = 0;
        service_key.function_key.kind = DPU_FUNCTION_PF;
        service_key.function_key.vf_id = 0;
        service_key.service_kind = DPU_SERVICE_VIO_NET;
        service_key.service_instance_id = 0;
        message = "";
    endfunction

    function void set(
        input dpu_placement_stage_e new_stage,
        input dpu_placement_error_e new_error_code,
        input string new_message
    );
        clear();
        stage = new_stage;
        error_code = new_error_code;
        message = new_message;
    endfunction

    function void set_request_context(input int unsigned value);
        has_request_id = 1;
        request_id = value;
    endfunction

    function void set_function_context(input dpu_function_key_t value);
        has_function_key = 1;
        function_key = value;
    endfunction

    function void set_service_context(input dpu_service_key_t value);
        has_service_key = 1;
        service_key = value;
    endfunction

    function void set_pair_context(input int unsigned value);
        has_pair_index = 1;
        request_pair_index = value;
    endfunction

    function void set_device_resolution_failure(input string detail);
        set(DPU_PLACE_STAGE_DEVICE_RESOLUTION,
            DPU_PLACE_ERR_DEVICE_RESOLUTION_FAILED, detail);
    endfunction

    function void copy_from(input dpu_placement_diagnostic rhs);
        stage = rhs.stage;
        error_code = rhs.error_code;
        has_request_id = rhs.has_request_id;
        has_function_key = rhs.has_function_key;
        has_service_key = rhs.has_service_key;
        has_pair_index = rhs.has_pair_index;
        request_id = rhs.request_id;
        request_pair_index = rhs.request_pair_index;
        function_key = rhs.function_key;
        service_key = rhs.service_key;
        message = rhs.message;
    endfunction

    virtual function void do_copy(uvm_object rhs);
        dpu_placement_diagnostic typed_rhs;

        super.do_copy(rhs);
        if (!$cast(typed_rhs, rhs)) begin
            `uvm_error("DPU_CFG_COPY", "placement diagnostic copy received incompatible object")
            return;
        end
        copy_from(typed_rhs);
    endfunction
endclass : dpu_placement_diagnostic

`endif // DPU_PLACEMENT_CFG_SV
