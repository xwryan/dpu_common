// 资源解析结果快照：VIO qpair、AF extra queue、控制中断向量、每 Function 的 MSI-X 向量块、保留区间及反向索引；freeze 后只读。
`ifndef DPU_RESOURCE_SNAPSHOT_SV
`define DPU_RESOURCE_SNAPSHOT_SV

class dpu_resource_snapshot extends uvm_object;
    `uvm_object_utils(dpu_resource_snapshot)

    protected bit m_frozen;
    protected dpu_normalized_placement_plan m_plan;
    protected dpu_device_snapshot m_device_snapshot;
    protected dpu_vio_qpair_binding_t m_bindings[$];
    protected dpu_af_extra_queue_binding_t m_af_extra_bindings[$];
    protected dpu_msix_control_binding_t m_msix_control_bindings[$];
    protected dpu_msix_vector_block_t m_msix_blocks[$];
    protected int unsigned m_request_index[string];
    protected int unsigned m_service_local_index[string];
    protected int unsigned m_service_virtio_pair_index[string];
    protected int unsigned m_global_index[string];
    protected int unsigned m_af_extra_offset_index[string];
    protected int unsigned m_af_extra_global_index[string];
    protected int unsigned m_reserved_ids[$];
    protected dpu_global_id_range_t m_reserved_ranges[$];
    protected dpu_resource_pool_config_t m_profiles[$];

    function new(string name = "dpu_resource_snapshot");
        super.new(name);
        m_frozen = 0;
        m_plan = null;
        m_device_snapshot = null;
    endfunction

    protected function void ensure_diagnostic(
        output dpu_placement_diagnostic diagnostic
    );
        if (diagnostic == null)
            diagnostic = dpu_placement_diagnostic::type_id::create(
                {get_name(), "_diagnostic"});
    endfunction

    protected function void set_failure(
        output dpu_placement_diagnostic diagnostic,
        input dpu_placement_error_e error_code,
        input string message
    );
        ensure_diagnostic(diagnostic);
        diagnostic.set(DPU_PLACE_STAGE_RESOURCE_RESOLUTION, error_code,
                       message);
    endfunction

    protected function string request_key(
        input int unsigned request_id,
        input int unsigned request_pair_index
    );
        return $sformatf("%0d:%0d", request_id, request_pair_index);
    endfunction

    protected function string service_local_key(
        input dpu_service_key_t service_key,
        input int unsigned local_pair_id
    );
        return {dpu_service_key_name(service_key),
                $sformatf(":%0d", local_pair_id)};
    endfunction

    protected function string service_virtio_pair_key(
        input dpu_service_key_t service_key,
        input int unsigned virtio_pair_index
    );
        return {dpu_service_key_name(service_key),
                $sformatf(":%0d", virtio_pair_index)};
    endfunction

    protected function string global_key(input int unsigned global_qpair_id);
        return $sformatf("%0d", global_qpair_id);
    endfunction

    protected function bit mutable(output dpu_placement_diagnostic diagnostic);
        ensure_diagnostic(diagnostic);
        diagnostic.clear();
        if (m_frozen) begin
            set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                        "resource snapshot is frozen");
            return 0;
        end
        return 1;
    endfunction

    protected function bit binding_less(
        input dpu_vio_qpair_binding_t lhs,
        input dpu_vio_qpair_binding_t rhs
    );
        return (lhs.request_id < rhs.request_id) ||
            ((lhs.request_id == rhs.request_id) &&
             (lhs.request_pair_index < rhs.request_pair_index));
    endfunction

    protected function void sort_bindings();
        dpu_vio_qpair_binding_t swap;
        for (int left = 0; left < m_bindings.size(); left++) begin
            for (int right = left + 1; right < m_bindings.size(); right++) begin
                if (binding_less(m_bindings[right], m_bindings[left])) begin
                    swap = m_bindings[left];
                    m_bindings[left] = m_bindings[right];
                    m_bindings[right] = swap;
                end
            end
        end
    endfunction

    protected function void sort_af_extra_bindings();
        dpu_af_extra_queue_binding_t swap;
        for (int left = 0; left < m_af_extra_bindings.size(); left++) begin
            for (int right = left + 1;
                 right < m_af_extra_bindings.size(); right++) begin
                if (m_af_extra_bindings[right].extra_queue_offset <
                    m_af_extra_bindings[left].extra_queue_offset) begin
                    swap = m_af_extra_bindings[left];
                    m_af_extra_bindings[left] = m_af_extra_bindings[right];
                    m_af_extra_bindings[right] = swap;
                end
            end
        end
    endfunction

    protected function void rebuild_indexes();
        m_request_index.delete();
        m_service_local_index.delete();
        m_service_virtio_pair_index.delete();
        m_global_index.delete();
        m_af_extra_offset_index.delete();
        m_af_extra_global_index.delete();
        foreach (m_bindings[index]) begin
            m_request_index[request_key(m_bindings[index].request_id,
                                        m_bindings[index].request_pair_index)] = index;
            m_service_local_index[service_local_key(m_bindings[index].service_key,
                                                    m_bindings[index].local_pair_id)] = index;
            m_service_virtio_pair_index[service_virtio_pair_key(
                m_bindings[index].service_key,
                m_bindings[index].virtio_pair_index)] = index;
            m_global_index[global_key(m_bindings[index].global_qpair_id)] = index;
        end
        foreach (m_af_extra_bindings[index]) begin
            m_af_extra_offset_index[$sformatf(
                "%0d", m_af_extra_bindings[index].extra_queue_offset)] = index;
            m_af_extra_global_index[global_key(
                m_af_extra_bindings[index].global_qpair_id)] = index;
        end
    endfunction

    protected function void clear_binding(
        output dpu_vio_qpair_binding_t binding
    );
        binding.request_id = 0;
        binding.request_pair_index = 0;
        binding.service_key.function_key.host_id = 0;
        binding.service_key.function_key.pf_id = 0;
        binding.service_key.function_key.kind = DPU_FUNCTION_PF;
        binding.service_key.function_key.vf_id = 0;
        binding.service_key.service_kind = DPU_SERVICE_VIO_NET;
        binding.service_key.service_instance_id = 0;
        binding.virtio_pair_index = 0;
        binding.local_pair_id = 0;
        binding.rx_local_virtqueue_id = 0;
        binding.tx_local_virtqueue_id = 0;
        binding.global_qpair_id = 0;
        binding.local_msix_vector_id = 0;
        binding.global_msix_vector_id = 0;
    endfunction

    protected function void sort_and_merge_ranges(
        ref dpu_global_id_range_t ranges[$]
    );
        dpu_global_id_range_t swap;
        dpu_global_id_range_t result[$];
        for (int left = 0; left < ranges.size(); left++) begin
            for (int right = left + 1; right < ranges.size(); right++) begin
                if ((ranges[right].first_id < ranges[left].first_id) ||
                    ((ranges[right].first_id == ranges[left].first_id) &&
                     (ranges[right].last_id < ranges[left].last_id))) begin
                    swap = ranges[left];
                    ranges[left] = ranges[right];
                    ranges[right] = swap;
                end
            end
        end
        foreach (ranges[index]) begin
            if ((result.size() == 0) ||
                (ranges[index].first_id > result[result.size() - 1].last_id + 1)) begin
                result.push_back(ranges[index]);
            end else if (ranges[index].last_id > result[result.size() - 1].last_id) begin
                result[result.size() - 1].last_id = ranges[index].last_id;
            end
        end
        ranges = result;
    endfunction

    protected function void canonicalize_reservations(
        ref int unsigned ids[$],
        ref dpu_global_id_range_t ranges[$]
    );
        dpu_global_id_range_t intervals[$];

        intervals = ranges;
        foreach (ids[index]) begin
            intervals.push_back('{first_id: ids[index], last_id: ids[index]});
        end
        sort_and_merge_ranges(intervals);
        ids.delete();
        ranges.delete();
        foreach (intervals[index]) begin
            if (intervals[index].first_id == intervals[index].last_id)
                ids.push_back(intervals[index].first_id);
            else
                ranges.push_back(intervals[index]);
        end
    endfunction

    protected function bit copy_plan(
        input dpu_normalized_placement_plan source,
        output dpu_normalized_placement_plan copied,
        output int unsigned reservation_ids[$],
        output dpu_global_id_range_t reservation_ranges[$],
        output dpu_resource_pool_config_t profiles[$],
        output dpu_placement_diagnostic diagnostic
    );
        dpu_normalized_vio_request requests[$];
        dpu_function_key_t control_functions[$];
        string why;

        copied = null;
        reservation_ids.delete();
        reservation_ranges.delete();
        profiles.delete();
        if ((source == null) || !source.is_frozen()) begin
            set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                        "normalized placement plan must be frozen");
            return 0;
        end
        source.list_requests(requests);
        source.list_reserved_global_qpair_ids(reservation_ids);
        source.list_reserved_global_qpair_ranges(reservation_ranges);
        source.list_resource_profiles(profiles);
        source.list_msix_control_functions(control_functions);
        canonicalize_reservations(reservation_ids, reservation_ranges);
        copied = dpu_normalized_placement_plan::type_id::create(
            {get_name(), "_plan"});
        copied.effective_global_capacity = source.effective_global_capacity;
        copied.effective_device_capacity = source.effective_device_capacity;
        copied.set_profiles(profiles);
        copied.set_reservations(reservation_ids, reservation_ranges);
        copied.set_msix_control_functions(control_functions);
        foreach (requests[index]) begin
            if (!copied.add_request(requests[index], why)) begin
                set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                            {"cannot copy normalized placement plan: ", why});
                copied = null;
                return 0;
            end
        end
        if (!copied.freeze(why)) begin
            set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                        {"cannot freeze normalized placement plan copy: ", why});
            copied = null;
            return 0;
        end
        return 1;
    endfunction

    protected function bit validate_vio_service_topology(
        input dpu_device_snapshot snapshot,
        input dpu_service_key_t service_key,
        input int unsigned request_id,
        input bit has_pair_index,
        input int unsigned request_pair_index,
        output dpu_placement_diagnostic diagnostic
    );
        dpu_service_key_t services[$];
        int unsigned service_count;
        bit found_service;

        if (service_key.service_instance_id != 0) begin
            set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                        "VIO-net resource service instance must be zero");
            diagnostic.set_request_context(request_id);
            if (has_pair_index)
                diagnostic.set_pair_context(request_pair_index);
            diagnostic.set_service_context(service_key);
            diagnostic.set_function_context(service_key.function_key);
            return 0;
        end
        snapshot.list_services(DPU_SERVICE_VIO_NET, services);
        service_count = 0;
        found_service = 0;
        foreach (services[index]) begin
            if (dpu_same_function_key(services[index].function_key,
                                      service_key.function_key)) begin
                service_count++;
                if (dpu_service_key_name(services[index]) ==
                    dpu_service_key_name(service_key))
                    found_service = 1;
            end
        end
        if (!found_service) begin
            set_failure(diagnostic, DPU_PLACE_ERR_SNAPSHOT_REFERENCE_MISMATCH,
                        "participating VIO-net service is absent from device snapshot");
            diagnostic.set_request_context(request_id);
            if (has_pair_index)
                diagnostic.set_pair_context(request_pair_index);
            diagnostic.set_service_context(service_key);
            diagnostic.set_function_context(service_key.function_key);
            return 0;
        end
        if (service_count != 1) begin
            set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                        "participating function must expose exactly one VIO-net service");
            diagnostic.set_request_context(request_id);
            if (has_pair_index)
                diagnostic.set_pair_context(request_pair_index);
            diagnostic.set_service_context(service_key);
            diagnostic.set_function_context(service_key.function_key);
            return 0;
        end
        return 1;
    endfunction

    protected function bit validate_bindings(
        input dpu_device_snapshot device_snapshot,
        output dpu_placement_diagnostic diagnostic
    );
        dpu_normalized_vio_request request;
        dpu_normalized_vio_pair_t pairs[$];
        dpu_vio_participant_target_t targets[$];
        bit pair_keys[string];
        bit msix_occupied[DPU_MAX_GLOBAL_MSIX_VECTORS];
        dpu_function_key_t msix_owner[DPU_MAX_GLOBAL_MSIX_VECTORS];
        int unsigned msix_local[DPU_MAX_GLOBAL_MSIX_VECTORS];
        int unsigned function_local_global[string];
        dpu_dut_caps caps;
        dpu_function_key_t expected_af_key;
        dpu_bar_pair_lease_t expected_af_bar0;
        int unsigned af_regular_qpair_count;
        int unsigned af_lan_msix_count;
        int unsigned af_msix_base;
        bit af_msix_base_valid;
        string caps_why;

        msix_occupied = '{default: 0};
        caps = device_snapshot.snapshot_dut_caps();
        if ((caps == null) || !caps.validate(caps_why)) begin
            set_failure(diagnostic, DPU_PLACE_ERR_INVALID_PROFILE,
                        (caps == null) ?
                        "resource snapshot cannot read DUT capabilities" :
                        {"resource snapshot has invalid DUT capabilities: ",
                         caps_why});
            return 0;
        end
        if (!device_snapshot.get_expected_af(expected_af_key,
                                             expected_af_bar0, caps_why)) begin
            set_failure(diagnostic, DPU_PLACE_ERR_SNAPSHOT_REFERENCE_MISMATCH,
                        {"resource snapshot cannot resolve AF: ", caps_why});
            return 0;
        end
        af_regular_qpair_count = 0;
        af_lan_msix_count = 0;
        af_msix_base = 0;
        af_msix_base_valid = 0;
        foreach (m_bindings[index]) begin
            if (dpu_same_function_key(
                    m_bindings[index].service_key.function_key,
                    expected_af_key)) begin
                int unsigned candidate_base;
                af_regular_qpair_count++;
                if ((m_bindings[index].local_msix_vector_id + 1) >
                    af_lan_msix_count)
                    af_lan_msix_count =
                        m_bindings[index].local_msix_vector_id + 1;
                if (m_bindings[index].global_msix_vector_id <
                    m_bindings[index].local_msix_vector_id) begin
                    set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                                "AF VIO MSI-X binding has an invalid vector base");
                    return 0;
                end
                candidate_base = m_bindings[index].global_msix_vector_id -
                                 m_bindings[index].local_msix_vector_id;
                if (af_msix_base_valid && (candidate_base != af_msix_base)) begin
                    set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                                "AF VIO MSI-X bindings disagree on the function vector base");
                    return 0;
                end
                af_msix_base = candidate_base;
                af_msix_base_valid = 1;
            end
        end

        if ((m_plan == null) || !m_plan.is_frozen()) begin
            set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                        "resource snapshot has no frozen normalized placement plan");
            return 0;
        end
        if ((m_plan.effective_global_capacity == 0) ||
            (m_plan.effective_device_capacity == 0)) begin
            set_failure(diagnostic, DPU_PLACE_ERR_INVALID_PROFILE,
                        "normalized placement plan has no effective qpair capacity");
            return 0;
        end
        begin
            dpu_normalized_vio_request requests[$];
            m_plan.list_requests(requests);
            foreach (requests[request_index]) begin
                int unsigned hard_device_capacity;

                hard_device_capacity = (m_plan.effective_device_capacity <
                                        DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE) ?
                                       m_plan.effective_device_capacity :
                                       DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE;
                m_plan.list_targets(requests[request_index].request_id, targets);
                foreach (targets[target_index]) begin
                    if ((targets[target_index].qpair_count == 0) ||
                        (targets[target_index].qpair_count >
                         hard_device_capacity)) begin
                        set_failure(diagnostic,
                                    DPU_PLACE_ERR_DEVICE_CAPACITY_EXHAUSTED,
                                    "participant qpair count exceeds fixed VIO-net device ceiling");
                        diagnostic.set_request_context(requests[request_index].request_id);
                        diagnostic.set_service_context(targets[target_index].service_key);
                        return 0;
                    end
                    if (!validate_vio_service_topology(
                            device_snapshot, targets[target_index].service_key,
                            requests[request_index].request_id, 0, 0,
                            diagnostic))
                        return 0;
                end
            end
        end
        foreach (m_bindings[index]) begin
            string key;

            if (!m_plan.get_request(m_bindings[index].request_id, request)) begin
                set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                            "binding has an unknown normalized request");
                diagnostic.set_request_context(m_bindings[index].request_id);
                diagnostic.set_pair_context(m_bindings[index].request_pair_index);
                return 0;
            end
            m_plan.list_pairs(m_bindings[index].request_id, pairs);
            key = request_key(m_bindings[index].request_id,
                              m_bindings[index].request_pair_index);
            pair_keys[key] = 0;
            foreach (pairs[pair_index]) begin
                if (pairs[pair_index].request_pair_index ==
                    m_bindings[index].request_pair_index) begin
                    if (dpu_service_key_name(pairs[pair_index].service_key) !=
                        dpu_service_key_name(m_bindings[index].service_key)) begin
                        set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                                    "binding service disagrees with normalized pair");
                        diagnostic.set_request_context(m_bindings[index].request_id);
                        diagnostic.set_pair_context(m_bindings[index].request_pair_index);
                        return 0;
                    end
                    pair_keys[key] = 1;
                    break;
                end
            end
            if (!pair_keys[key]) begin
                set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                            "binding has an unknown normalized pair");
                diagnostic.set_request_context(m_bindings[index].request_id);
                diagnostic.set_pair_context(m_bindings[index].request_pair_index);
                return 0;
            end
            if ((m_bindings[index].service_key.service_kind != DPU_SERVICE_VIO_NET) ||
                !validate_vio_service_topology(
                    device_snapshot, m_bindings[index].service_key,
                    m_bindings[index].request_id, 1,
                    m_bindings[index].request_pair_index, diagnostic))
                return 0;
            if ((m_bindings[index].local_pair_id >=
                 DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE) ||
                (m_bindings[index].local_pair_id >=
                 m_plan.effective_device_capacity)) begin
                set_failure(diagnostic, DPU_PLACE_ERR_LOCAL_QID_OUT_OF_RANGE,
                            "binding local qpair ID exceeds effective device capacity");
                diagnostic.set_request_context(m_bindings[index].request_id);
                diagnostic.set_pair_context(m_bindings[index].request_pair_index);
                diagnostic.set_service_context(m_bindings[index].service_key);
                return 0;
            end
            if (m_bindings[index].virtio_pair_index >=
                m_plan.effective_device_capacity ||
                (m_bindings[index].rx_local_virtqueue_id !=
                 2 * m_bindings[index].virtio_pair_index) ||
                (m_bindings[index].tx_local_virtqueue_id !=
                 (2 * m_bindings[index].virtio_pair_index + 1)) ||
                (m_bindings[index].rx_local_virtqueue_id >= 64) ||
                (m_bindings[index].tx_local_virtqueue_id >= 64)) begin
                set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                            "binding virtqueue IDs are not derived from software pair index");
                diagnostic.set_request_context(m_bindings[index].request_id);
                diagnostic.set_pair_context(m_bindings[index].request_pair_index);
                diagnostic.set_service_context(m_bindings[index].service_key);
                return 0;
            end
            if ((m_bindings[index].global_qpair_id >=
                 DPU_MAX_VIO_GLOBAL_QPAIRS) ||
                (m_bindings[index].global_qpair_id >=
                 m_plan.effective_global_capacity)) begin
                set_failure(diagnostic, DPU_PLACE_ERR_GLOBAL_QID_OUT_OF_RANGE,
                            "binding global qpair ID exceeds effective global capacity");
                diagnostic.set_request_context(m_bindings[index].request_id);
                diagnostic.set_pair_context(m_bindings[index].request_pair_index);
                diagnostic.set_service_context(m_bindings[index].service_key);
                return 0;
            end
            if ((m_bindings[index].local_msix_vector_id >= 128) ||
                (m_bindings[index].global_msix_vector_id >=
                 caps.global_msix_vector_count)) begin
                set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                            "binding MSI-X vector is outside the driver table domain");
                diagnostic.set_request_context(m_bindings[index].request_id);
                diagnostic.set_pair_context(m_bindings[index].request_pair_index);
                diagnostic.set_service_context(m_bindings[index].service_key);
                return 0;
            end
            if (msix_occupied[m_bindings[index].global_msix_vector_id] &&
                (!dpu_same_function_key(
                    msix_owner[m_bindings[index].global_msix_vector_id],
                    m_bindings[index].service_key.function_key) ||
                 (msix_local[m_bindings[index].global_msix_vector_id] !=
                  m_bindings[index].local_msix_vector_id))) begin
                set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                            "binding global MSI-X vector conflicts with another function or local vector");
                diagnostic.set_request_context(m_bindings[index].request_id);
                diagnostic.set_pair_context(m_bindings[index].request_pair_index);
                diagnostic.set_service_context(m_bindings[index].service_key);
                return 0;
            end
            if (!msix_occupied[m_bindings[index].global_msix_vector_id]) begin
                msix_occupied[m_bindings[index].global_msix_vector_id] = 1;
                msix_owner[m_bindings[index].global_msix_vector_id] =
                    m_bindings[index].service_key.function_key;
                msix_local[m_bindings[index].global_msix_vector_id] =
                    m_bindings[index].local_msix_vector_id;
            end
            begin
                string function_local_key;
                function_local_key = {dpu_function_key_name(
                    m_bindings[index].service_key.function_key), ":",
                    $sformatf("%0d", m_bindings[index].local_msix_vector_id)};
                if (function_local_global.exists(function_local_key) &&
                    (function_local_global[function_local_key] !=
                     m_bindings[index].global_msix_vector_id)) begin
                    set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                                "local MSI-X vector maps to multiple global vectors");
                    diagnostic.set_request_context(m_bindings[index].request_id);
                    diagnostic.set_pair_context(m_bindings[index].request_pair_index);
                    diagnostic.set_service_context(m_bindings[index].service_key);
                    return 0;
                end
                function_local_global[function_local_key] =
                    m_bindings[index].global_msix_vector_id;
            end
        end
        if (m_af_extra_bindings.size() != caps.af_extra_queue_count) begin
            set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                        "AF extra queue binding count disagrees with DUT capability");
            diagnostic.set_function_context(expected_af_key);
            return 0;
        end
        if ((af_regular_qpair_count + m_af_extra_bindings.size()) >
            caps.max_vio_net_qpairs_per_device) begin
            set_failure(diagnostic, DPU_PLACE_ERR_DEVICE_CAPACITY_EXHAUSTED,
                        "AF ordinary and extra qpairs exceed the per-device ceiling");
            diagnostic.set_function_context(expected_af_key);
            return 0;
        end
        foreach (m_af_extra_bindings[index]) begin
            dpu_af_extra_queue_kind_e expected_kind;
            int unsigned expected_port;
            int unsigned expected_queue;
            int unsigned candidate_base;
            string function_local_key;

            if (!dpu_same_function_key(
                    m_af_extra_bindings[index].af_function_key,
                    expected_af_key)) begin
                set_failure(diagnostic, DPU_PLACE_ERR_SNAPSHOT_REFERENCE_MISMATCH,
                            "AF extra queue binding owner is not the selected AF");
                diagnostic.set_function_context(
                    m_af_extra_bindings[index].af_function_key);
                return 0;
            end
            if ((m_af_extra_bindings[index].extra_queue_offset != index) ||
                !dpu_decode_af_extra_queue_offset(
                    m_af_extra_bindings[index].extra_queue_offset,
                    expected_kind, expected_port, expected_queue) ||
                (m_af_extra_bindings[index].kind != expected_kind) ||
                (m_af_extra_bindings[index].eth_port_id != expected_port) ||
                (m_af_extra_bindings[index].eth_queue_id != expected_queue)) begin
                set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                            "AF extra queue binding disagrees with the driver layout");
                diagnostic.set_function_context(expected_af_key);
                return 0;
            end
            if (m_af_extra_bindings[index].local_queue_index !=
                (af_regular_qpair_count + index)) begin
                set_failure(diagnostic, DPU_PLACE_ERR_LOCAL_QID_OUT_OF_RANGE,
                            "AF extra queue local index is not appended after LAN qpairs");
                diagnostic.set_function_context(expected_af_key);
                return 0;
            end
            if ((m_af_extra_bindings[index].global_qpair_id >=
                 m_plan.effective_global_capacity) ||
                (m_af_extra_bindings[index].global_qpair_id >=
                 DPU_MAX_VIO_GLOBAL_QPAIRS)) begin
                set_failure(diagnostic, DPU_PLACE_ERR_GLOBAL_QID_OUT_OF_RANGE,
                            "AF extra queue global qpair ID exceeds effective capacity");
                diagnostic.set_function_context(expected_af_key);
                return 0;
            end
            if (m_af_extra_bindings[index].local_msix_vector_id !=
                (af_lan_msix_count + index)) begin
                set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                            "AF extra queue MSI-X vector is not appended after LAN vectors");
                diagnostic.set_function_context(expected_af_key);
                return 0;
            end
            if ((m_af_extra_bindings[index].local_msix_vector_id >= 128) ||
                (m_af_extra_bindings[index].global_msix_vector_id >=
                 caps.global_msix_vector_count) ||
                (m_af_extra_bindings[index].global_msix_vector_id <
                 m_af_extra_bindings[index].local_msix_vector_id)) begin
                set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                            "AF extra queue MSI-X vector is outside the driver table domain");
                diagnostic.set_function_context(expected_af_key);
                return 0;
            end
            candidate_base =
                m_af_extra_bindings[index].global_msix_vector_id -
                m_af_extra_bindings[index].local_msix_vector_id;
            if (af_msix_base_valid && (candidate_base != af_msix_base)) begin
                set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                            "AF extra queue MSI-X binding disagrees with the function vector base");
                diagnostic.set_function_context(expected_af_key);
                return 0;
            end
            af_msix_base = candidate_base;
            af_msix_base_valid = 1;
            if (msix_occupied[
                    m_af_extra_bindings[index].global_msix_vector_id]) begin
                set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                            "AF extra queue global MSI-X vector conflicts with another binding");
                diagnostic.set_function_context(expected_af_key);
                return 0;
            end
            msix_occupied[m_af_extra_bindings[index].global_msix_vector_id] = 1;
            msix_owner[m_af_extra_bindings[index].global_msix_vector_id] =
                expected_af_key;
            msix_local[m_af_extra_bindings[index].global_msix_vector_id] =
                m_af_extra_bindings[index].local_msix_vector_id;
            function_local_key = {dpu_function_key_name(expected_af_key), ":",
                $sformatf("%0d",
                    m_af_extra_bindings[index].local_msix_vector_id)};
            if (function_local_global.exists(function_local_key) &&
                (function_local_global[function_local_key] !=
                 m_af_extra_bindings[index].global_msix_vector_id)) begin
                set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                            "AF extra local MSI-X vector maps to multiple global vectors");
                diagnostic.set_function_context(expected_af_key);
                return 0;
            end
            function_local_global[function_local_key] =
                m_af_extra_bindings[index].global_msix_vector_id;
        end
        if (!validate_msix_control_bindings(device_snapshot, caps, expected_af_key,
                                            msix_occupied, msix_owner, msix_local,
                                            function_local_global, diagnostic))
            return 0;
        if (!validate_msix_vector_blocks(device_snapshot, caps, diagnostic))
            return 0;
        begin
            dpu_normalized_vio_request requests[$];
            m_plan.list_requests(requests);
            foreach (requests[request_index]) begin
                int unsigned request_count;
                m_plan.list_pairs(requests[request_index].request_id, pairs);
                if (pairs.size() != requests[request_index].total_qpairs) begin
                    set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                                "normalized request pair count disagrees with total");
                    diagnostic.set_request_context(requests[request_index].request_id);
                    return 0;
                end
                request_count = 0;
                foreach (pairs[pair_index]) begin
                    string key;
                    key = request_key(requests[request_index].request_id,
                                      pairs[pair_index].request_pair_index);
                    if (!m_request_index.exists(key)) begin
                        set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                                    "normalized pair has no resource binding");
                        diagnostic.set_request_context(requests[request_index].request_id);
                        diagnostic.set_pair_context(pairs[pair_index].request_pair_index);
                        return 0;
                    end
                    request_count++;
                end
                if (request_count != requests[request_index].total_qpairs) begin
                    set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                                "resource binding count disagrees with normalized total");
                    return 0;
                end
                m_plan.list_targets(requests[request_index].request_id, targets);
                foreach (targets[target_index]) begin
                    int unsigned participant_count;
                    participant_count = 0;
                    foreach (m_bindings[binding_index]) begin
                        if ((m_bindings[binding_index].request_id ==
                             requests[request_index].request_id) &&
                            (dpu_service_key_name(m_bindings[binding_index].service_key) ==
                             dpu_service_key_name(targets[target_index].service_key)))
                            participant_count++;
                    end
                    if (participant_count != targets[target_index].qpair_count) begin
                        set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                                    "participant binding count disagrees with target");
                        diagnostic.set_service_context(targets[target_index].service_key);
                        return 0;
                    end
                end
            end
        end
        return 1;
    endfunction

    // 控制中断向量须按驱动布局紧跟 LAN 前缀（AF 在额外队列向量之后），与本 Function 其他向量同一基址，
    // 全局号不与任何其他绑定重叠。LAN 数取本 Function VIO 绑定的最大 local 向量 + 1，没有 VIO 绑定为 0。
    protected function bit validate_msix_control_bindings(
        input dpu_device_snapshot device_snapshot,
        input dpu_dut_caps caps,
        input dpu_function_key_t af_key,
        ref bit msix_occupied[DPU_MAX_GLOBAL_MSIX_VECTORS],
        ref dpu_function_key_t msix_owner[DPU_MAX_GLOBAL_MSIX_VECTORS],
        ref int unsigned msix_local[DPU_MAX_GLOBAL_MSIX_VECTORS],
        ref int unsigned function_local_global[string],
        output dpu_placement_diagnostic diagnostic
    );
        dpu_function_key_t keys[$];
        int unsigned lan_count[string];
        int unsigned base[string];
        bit seen[string];

        device_snapshot.list_functions(keys);
        foreach (m_bindings[index]) begin
            string name;
            name = dpu_function_key_name(m_bindings[index].service_key.function_key);
            if (!lan_count.exists(name) ||
                (m_bindings[index].local_msix_vector_id + 1 > lan_count[name]))
                lan_count[name] = m_bindings[index].local_msix_vector_id + 1;
            base[name] = m_bindings[index].global_msix_vector_id -
                         m_bindings[index].local_msix_vector_id;
        end
        foreach (m_af_extra_bindings[index])
            base[dpu_function_key_name(af_key)] =
                m_af_extra_bindings[index].global_msix_vector_id -
                m_af_extra_bindings[index].local_msix_vector_id;
        foreach (m_msix_control_bindings[index]) begin
            dpu_msix_control_binding_t b;
            string name;
            string seen_key;
            bit known;
            bit is_af;
            int unsigned lan;
            int unsigned expected_local;

            b = m_msix_control_bindings[index];
            name = dpu_function_key_name(b.function_key);
            known = 0;
            foreach (keys[k])
                if (dpu_same_function_key(keys[k], b.function_key))
                    known = 1;
            is_af = dpu_same_function_key(b.function_key, af_key);
            lan = lan_count.exists(name) ? lan_count[name] : 0;
            expected_local = lan + (is_af ? caps.af_extra_queue_count + int'(b.kind) : 0);
            seen_key = $sformatf("%s:%0d", name, b.kind);
            if (!known || (!is_af && (b.kind != DPU_MSIX_CONTROL_MAILBOX)) || seen.exists(seen_key) ||
                (b.local_msix_vector_id != expected_local)) begin
                set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                            "MSI-X control binding disagrees with the driver vector layout");
                diagnostic.set_function_context(b.function_key);
                return 0;
            end
            seen[seen_key] = 1;
            if ((b.local_msix_vector_id >= 128) ||
                (b.global_msix_vector_id >= caps.global_msix_vector_count) ||
                (b.global_msix_vector_id < b.local_msix_vector_id) ||
                (base.exists(name) &&
                 (b.global_msix_vector_id - b.local_msix_vector_id != base[name]))) begin
                set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                            "MSI-X control vector is outside the driver table domain or the function base");
                diagnostic.set_function_context(b.function_key);
                return 0;
            end
            base[name] = b.global_msix_vector_id - b.local_msix_vector_id;
            if (msix_occupied[b.global_msix_vector_id]) begin
                set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                            "MSI-X control vector conflicts with another binding");
                diagnostic.set_function_context(b.function_key);
                return 0;
            end
            msix_occupied[b.global_msix_vector_id] = 1;
            msix_owner[b.global_msix_vector_id] = b.function_key;
            msix_local[b.global_msix_vector_id] = b.local_msix_vector_id;
            function_local_global[$sformatf("%s:%0d", name, b.local_msix_vector_id)] =
                b.global_msix_vector_id;
        end
        return 1;
    endfunction

    // resolver 记录的向量块互不重叠、在 DUT 容量内，每个绑定（VIO、AF 额外队列、控制中断）都在本 Function 的块内且
    // global = base + local。手工构建、没有记录块的快照不检查（向量租约要求快照有块）。
    protected function bit validate_msix_vector_blocks(
        input dpu_device_snapshot device_snapshot,
        input dpu_dut_caps caps,
        output dpu_placement_diagnostic diagnostic
    );
        dpu_function_key_t keys[$];
        dpu_function_key_t owners[$];
        int unsigned locals[$];
        int unsigned globals[$];
        int unsigned base[string];
        int unsigned count[string];

        if (m_msix_blocks.size() == 0)
            return 1;
        device_snapshot.list_functions(keys);
        foreach (m_msix_blocks[index]) begin
            dpu_msix_vector_block_t b;
            bit known;

            b = m_msix_blocks[index];
            known = 0;
            foreach (keys[k])
                if (dpu_same_function_key(keys[k], b.function_key))
                    known = 1;
            if (!known || (b.vector_count == 0) ||
                (b.global_base + b.vector_count > caps.global_msix_vector_count)) begin
                set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                            "MSI-X vector block has an unknown owner or exceeds DUT global vector capacity");
                diagnostic.set_function_context(b.function_key);
                return 0;
            end
            foreach (m_msix_blocks[other])
                if ((other < index) &&
                    (b.global_base < m_msix_blocks[other].global_base + m_msix_blocks[other].vector_count) &&
                    (m_msix_blocks[other].global_base < b.global_base + b.vector_count)) begin
                    set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                                "MSI-X vector blocks overlap");
                    diagnostic.set_function_context(b.function_key);
                    return 0;
                end
            base[dpu_function_key_name(b.function_key)] = b.global_base;
            count[dpu_function_key_name(b.function_key)] = b.vector_count;
        end
        foreach (m_bindings[index]) begin
            owners.push_back(m_bindings[index].service_key.function_key);
            locals.push_back(m_bindings[index].local_msix_vector_id);
            globals.push_back(m_bindings[index].global_msix_vector_id);
        end
        foreach (m_af_extra_bindings[index]) begin
            owners.push_back(m_af_extra_bindings[index].af_function_key);
            locals.push_back(m_af_extra_bindings[index].local_msix_vector_id);
            globals.push_back(m_af_extra_bindings[index].global_msix_vector_id);
        end
        foreach (m_msix_control_bindings[index]) begin
            owners.push_back(m_msix_control_bindings[index].function_key);
            locals.push_back(m_msix_control_bindings[index].local_msix_vector_id);
            globals.push_back(m_msix_control_bindings[index].global_msix_vector_id);
        end
        foreach (owners[index]) begin
            string name;

            name = dpu_function_key_name(owners[index]);
            if (!base.exists(name) || (locals[index] >= count[name]) ||
                (globals[index] != base[name] + locals[index])) begin
                set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                            "MSI-X binding lies outside its Function vector block");
                diagnostic.set_function_context(owners[index]);
                return 0;
            end
        end
        return 1;
    endfunction

    function bit set_normalized_plan(
        input dpu_normalized_placement_plan plan,
        output dpu_placement_diagnostic diagnostic
    );
        dpu_normalized_placement_plan copied;
        int unsigned reservation_ids[$];
        dpu_global_id_range_t reservation_ranges[$];
        dpu_resource_pool_config_t profiles[$];

        if (!mutable(diagnostic))
            return 0;
        if (m_plan != null) begin
            set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                        "resource snapshot normalized plan is already set");
            return 0;
        end
        if (!copy_plan(plan, copied, reservation_ids, reservation_ranges,
                       profiles, diagnostic))
            return 0;
        m_plan = copied;
        m_reserved_ids = reservation_ids;
        m_reserved_ranges = reservation_ranges;
        m_profiles = profiles;
        return 1;
    endfunction

    function bit add_vio_binding(
        input dpu_vio_qpair_binding_t binding,
        output dpu_placement_diagnostic diagnostic
    );
        string key;

        if (!mutable(diagnostic))
            return 0;
        if (m_plan == null) begin
            set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                        "resource snapshot requires a normalized plan before bindings");
            return 0;
        end
        key = request_key(binding.request_id, binding.request_pair_index);
        if (m_request_index.exists(key)) begin
            set_failure(diagnostic, DPU_PLACE_ERR_DUPLICATE_REQUEST,
                        "resource snapshot has a duplicate request/pair binding");
            return 0;
        end
        key = service_local_key(binding.service_key, binding.local_pair_id);
        if (m_service_local_index.exists(key)) begin
            set_failure(diagnostic, DPU_PLACE_ERR_LOCAL_QID_CONFLICT,
                        "resource snapshot has a duplicate service/local binding");
            return 0;
        end
        key = service_virtio_pair_key(binding.service_key,
                                      binding.virtio_pair_index);
        if (m_service_virtio_pair_index.exists(key)) begin
            set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                        "resource snapshot has a duplicate service/virtio pair binding");
            return 0;
        end
        key = global_key(binding.global_qpair_id);
        if (m_global_index.exists(key) || m_af_extra_global_index.exists(key)) begin
            set_failure(diagnostic, DPU_PLACE_ERR_GLOBAL_QID_CONFLICT,
                        "resource snapshot has a duplicate global binding");
            return 0;
        end
        m_bindings.push_back(binding);
        rebuild_indexes();
        return 1;
    endfunction

    function bit add_af_extra_queue_binding(
        input dpu_af_extra_queue_binding_t binding,
        output dpu_placement_diagnostic diagnostic
    );
        string key;

        if (!mutable(diagnostic))
            return 0;
        if (m_plan == null) begin
            set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                        "resource snapshot requires a normalized plan before AF extra bindings");
            return 0;
        end
        key = $sformatf("%0d", binding.extra_queue_offset);
        if (m_af_extra_offset_index.exists(key)) begin
            set_failure(diagnostic, DPU_PLACE_ERR_LOCAL_QID_CONFLICT,
                        "resource snapshot has a duplicate AF extra queue offset");
            return 0;
        end
        key = global_key(binding.global_qpair_id);
        if (m_global_index.exists(key) ||
            m_af_extra_global_index.exists(key)) begin
            set_failure(diagnostic, DPU_PLACE_ERR_GLOBAL_QID_CONFLICT,
                        "resource snapshot has a duplicate global qpair binding");
            return 0;
        end
        m_af_extra_bindings.push_back(binding);
        rebuild_indexes();
        return 1;
    endfunction

    // 每个 (Function, kind) 一项；布局与冲突在 freeze 时核对。
    function bit add_msix_control_binding(
        input dpu_msix_control_binding_t binding,
        output dpu_placement_diagnostic diagnostic
    );
        if (!mutable(diagnostic))
            return 0;
        foreach (m_msix_control_bindings[index]) begin
            if (dpu_same_function_key(m_msix_control_bindings[index].function_key,
                                      binding.function_key) &&
                (m_msix_control_bindings[index].kind == binding.kind)) begin
                set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                            "resource snapshot has a duplicate MSI-X control binding");
                diagnostic.set_function_context(binding.function_key);
                return 0;
            end
        end
        m_msix_control_bindings.push_back(binding);
        return 1;
    endfunction

    // 每个 Function 至多一个块；重叠与绑定归属在 freeze 时核对。
    function bit add_msix_vector_block(
        input dpu_msix_vector_block_t block,
        output dpu_placement_diagnostic diagnostic
    );
        if (!mutable(diagnostic))
            return 0;
        foreach (m_msix_blocks[index]) begin
            if (dpu_same_function_key(m_msix_blocks[index].function_key, block.function_key)) begin
                set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                            "resource snapshot has a duplicate MSI-X vector block");
                diagnostic.set_function_context(block.function_key);
                return 0;
            end
        end
        m_msix_blocks.push_back(block);
        return 1;
    endfunction

    function bit freeze(
        input dpu_device_snapshot device_snapshot,
        output dpu_placement_diagnostic diagnostic
    );
        if (!mutable(diagnostic))
            return 0;
        if ((device_snapshot == null) || !device_snapshot.is_frozen()) begin
            set_failure(diagnostic, DPU_PLACE_ERR_SNAPSHOT_REFERENCE_MISMATCH,
                        "resource snapshot requires a frozen device snapshot");
            return 0;
        end
        sort_bindings();
        sort_af_extra_bindings();
        rebuild_indexes();
        if (!validate_bindings(device_snapshot, diagnostic))
            return 0;
        m_device_snapshot = device_snapshot;
        m_frozen = 1;
        ensure_diagnostic(diagnostic);
        diagnostic.clear();
        return 1;
    endfunction

    function bit is_frozen();
        return m_frozen;
    endfunction

    function void list_vio_bindings(ref dpu_vio_qpair_binding_t bindings[$]);
        bindings.delete();
        if (m_frozen)
            bindings = m_bindings;
    endfunction

    function void list_af_extra_queue_bindings(
        ref dpu_af_extra_queue_binding_t bindings[$]
    );
        bindings.delete();
        if (m_frozen)
            bindings = m_af_extra_bindings;
    endfunction

    function void list_msix_control_bindings(
        ref dpu_msix_control_binding_t bindings[$]
    );
        bindings.delete();
        if (m_frozen)
            bindings = m_msix_control_bindings;
    endfunction

    // resolver 分给各 Function 的向量块（没有向量的 Function 不在其中）；未冻结或手工构建的快照返回空。
    function void list_msix_vector_blocks(ref dpu_msix_vector_block_t blocks[$]);
        blocks.delete();
        if (m_frozen)
            blocks = m_msix_blocks;
    endfunction

    // Function 的某个控制中断向量；未分配（无 VIO qpair 的非 AF Function 没有列入 msix_control_functions、
    // 非 AF 查 MSGQ、或 mailbox_msix_vectors 为 0）时返回 0。
    function bit get_msix_control_binding(
        input dpu_function_key_t function_key,
        input dpu_msix_control_kind_e kind,
        output dpu_msix_control_binding_t binding
    );
        dpu_msix_control_binding_t empty;

        binding = empty;
        if (!m_frozen)
            return 0;
        foreach (m_msix_control_bindings[index]) begin
            if (dpu_same_function_key(m_msix_control_bindings[index].function_key, function_key) &&
                (m_msix_control_bindings[index].kind == kind)) begin
                binding = m_msix_control_bindings[index];
                return 1;
            end
        end
        return 0;
    endfunction

    function bit get_vio_binding(
        input int unsigned request_id,
        input int unsigned request_pair_index,
        output dpu_vio_qpair_binding_t binding
    );
        string key;
        clear_binding(binding);
        if (!m_frozen)
            return 0;
        key = request_key(request_id, request_pair_index);
        if (!m_request_index.exists(key))
            return 0;
        binding = m_bindings[m_request_index[key]];
        return 1;
    endfunction

    function bit get_vio_binding_by_service_local(
        input dpu_service_key_t service_key,
        input int unsigned local_pair_id,
        output dpu_vio_qpair_binding_t binding
    );
        string key;
        clear_binding(binding);
        if (!m_frozen)
            return 0;
        key = service_local_key(service_key, local_pair_id);
        if (!m_service_local_index.exists(key))
            return 0;
        binding = m_bindings[m_service_local_index[key]];
        return 1;
    endfunction

    function bit get_vio_binding_by_service_virtio_pair(
        input dpu_service_key_t service_key,
        input int unsigned virtio_pair_index,
        output dpu_vio_qpair_binding_t binding
    );
        string key;
        clear_binding(binding);
        if (!m_frozen)
            return 0;
        key = service_virtio_pair_key(service_key, virtio_pair_index);
        if (!m_service_virtio_pair_index.exists(key))
            return 0;
        binding = m_bindings[m_service_virtio_pair_index[key]];
        return 1;
    endfunction

    function bit get_vio_binding_by_global(
        input int unsigned global_qpair_id,
        output dpu_vio_qpair_binding_t binding
    );
        string key;
        clear_binding(binding);
        if (!m_frozen)
            return 0;
        key = global_key(global_qpair_id);
        if (!m_global_index.exists(key))
            return 0;
        binding = m_bindings[m_global_index[key]];
        return 1;
    endfunction

    function void list_vio_bindings_for_service(
        input dpu_service_key_t service_key,
        ref dpu_vio_qpair_binding_t bindings[$]
    );
        bindings.delete();
        if (!m_frozen)
            return;
        foreach (m_bindings[index]) begin
            if (dpu_service_key_name(m_bindings[index].service_key) ==
                dpu_service_key_name(service_key))
                bindings.push_back(m_bindings[index]);
        end
    endfunction

    function void list_vio_participants(
        ref dpu_vio_participant_target_t participants[$]
    );
        dpu_normalized_vio_request requests[$];
        dpu_vio_participant_target_t targets[$];
        participants.delete();
        if (!m_frozen || (m_plan == null))
            return;
        m_plan.list_requests(requests);
        foreach (requests[index]) begin
            m_plan.list_targets(requests[index].request_id, targets);
            foreach (targets[target_index])
                participants.push_back(targets[target_index]);
        end
    endfunction

    function bit get_normalized_request(
        input int unsigned request_id,
        output dpu_normalized_vio_request request
    );
        request = null;
        if (!m_frozen || (m_plan == null))
            return 0;
        return m_plan.get_request(request_id, request);
    endfunction

    function void list_reserved_global_qpair_ids(ref int unsigned ids[$]);
        ids.delete();
        if (m_frozen)
            ids = m_reserved_ids;
    endfunction

    function void list_reserved_global_qpair_ranges(
        ref dpu_global_id_range_t ranges[$]
    );
        ranges.delete();
        if (m_frozen)
            ranges = m_reserved_ranges;
    endfunction

    function void list_resource_profiles(
        ref dpu_resource_pool_config_t profiles[$]
    );
        profiles.delete();
        if (m_frozen)
            profiles = m_profiles;
    endfunction

    function bit references_device_snapshot(input dpu_device_snapshot snapshot);
        return m_frozen && (snapshot != null) && (snapshot == m_device_snapshot);
    endfunction
endclass : dpu_resource_snapshot

`endif // DPU_RESOURCE_SNAPSHOT_SV
