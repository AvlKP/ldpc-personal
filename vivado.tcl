# This script was generated automatically by bender.
set ROOT "/foss/designs/ldpc_personal"
add_files -norecurse -fileset [current_fileset] [list \
    $ROOT/.bender/git/checkouts/tech_cells_generic-ec7551cd5d33f3e0/src/fpga/pad_functional_xilinx.sv \
    $ROOT/.bender/git/checkouts/tech_cells_generic-ec7551cd5d33f3e0/src/fpga/tc_clk_xilinx.sv \
    $ROOT/.bender/git/checkouts/tech_cells_generic-ec7551cd5d33f3e0/src/fpga/tc_sram_xilinx.sv \
    $ROOT/.bender/git/checkouts/tech_cells_generic-ec7551cd5d33f3e0/src/rtl/tc_sram_impl.sv \
]
add_files -norecurse -fileset [current_fileset] [list \
    $ROOT/.bender/git/checkouts/tech_cells_generic-ec7551cd5d33f3e0/src/deprecated/pulp_clock_gating_async.sv \
    $ROOT/.bender/git/checkouts/tech_cells_generic-ec7551cd5d33f3e0/src/deprecated/cluster_clk_cells.sv \
    $ROOT/.bender/git/checkouts/tech_cells_generic-ec7551cd5d33f3e0/src/deprecated/pulp_clk_cells.sv \
]
add_files -norecurse -fileset [current_fileset] [list \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/binary_to_gray.sv \
]
add_files -norecurse -fileset [current_fileset] [list \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/cb_filter_pkg.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/cc_onehot.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/cdc_reset_ctrlr_pkg.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/cf_math_pkg.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/clk_int_div.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/credit_counter.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/delta_counter.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/ecc_pkg.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/edge_propagator_tx.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/exp_backoff.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/fifo_v3.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/gray_to_binary.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/heaviside.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/isochronous_4phase_handshake.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/isochronous_spill_register.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/lfsr.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/lfsr_16bit.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/lfsr_8bit.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/lossy_valid_to_stream.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/mv_filter.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/onehot_to_bin.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/plru_tree.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/passthrough_stream_fifo.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/popcount.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/ring_buffer.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/rr_arb_tree.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/rstgen_bypass.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/serial_deglitch.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/shift_reg.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/shift_reg_gated.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/spill_register_flushable.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/stream_demux.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/stream_filter.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/stream_fork.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/stream_intf.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/stream_join_dynamic.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/stream_mux.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/stream_throttle.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/sub_per_hash.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/sync.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/sync_wedge.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/unread.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/read.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/addr_decode_dync.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/boxcar.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/cdc_2phase.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/cdc_4phase.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/clk_int_div_static.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/trip_counter.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/addr_decode.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/addr_decode_napot.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/multiaddr_decode.sv \
]
add_files -norecurse -fileset [current_fileset] [list \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/cb_filter.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/cdc_fifo_2phase.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/clk_mux_glitch_free.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/counter.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/ecc_decode.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/ecc_encode.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/edge_detect.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/lzc.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/max_counter.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/rstgen.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/spill_register.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/stream_delay.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/stream_fifo.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/stream_fork_dynamic.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/stream_join.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/cdc_reset_ctrlr.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/cdc_fifo_gray.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/fall_through_register.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/id_queue.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/stream_to_mem.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/stream_arbiter_flushable.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/stream_fifo_optimal_wrap.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/stream_register.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/stream_xbar.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/cdc_fifo_gray_clearable.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/cdc_2phase_clearable.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/mem_to_banks_detailed.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/stream_arbiter.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/stream_omega_net.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/mem_to_banks.sv \
]
add_files -norecurse -fileset [current_fileset] [list \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/deprecated/clock_divider_counter.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/deprecated/clk_div.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/deprecated/find_first_one.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/deprecated/generic_LFSR_8bit.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/deprecated/generic_fifo.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/deprecated/prioarbiter.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/deprecated/pulp_sync.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/deprecated/pulp_sync_wedge.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/deprecated/rrarbiter.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/deprecated/clock_divider.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/deprecated/fifo_v2.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/deprecated/fifo_v1.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/edge_propagator_ack.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/edge_propagator.sv \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/src/edge_propagator_rx.sv \
]
add_files -norecurse -fileset [current_fileset] [list \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_pkg.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_intf.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_atop_filter.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_burst_splitter_gran.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_burst_unwrap.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_bus_compare.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_cdc_dst.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_cdc_src.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_cut.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_delayer.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_demux_simple.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_dw_downsizer.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_dw_upsizer.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_fifo.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_fifo_delay_dyn.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_id_remap.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_id_prepend.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_inval_filter.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_isolate.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_join.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_lite_demux.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_lite_dw_converter.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_lite_from_mem.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_lite_join.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_lite_lfsr.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_lite_mailbox.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_lite_mux.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_lite_regs.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_lite_to_apb.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_lite_to_axi.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_modify_address.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_mux.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_rw_join.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_rw_split.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_serializer.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_slave_compare.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_throttle.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_to_detailed_mem.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_burst_splitter.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_cdc.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_demux.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_err_slv.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_dw_converter.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_from_mem.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_id_serialize.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_lfsr.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_multicut.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_to_axi_lite.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_to_mem.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_zero_mem.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_interleaved_xbar.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_iw_converter.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_lite_xbar.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_xbar_unmuxed.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_to_mem_banked.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_to_mem_interleaved.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_to_mem_split.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_xbar.sv \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/src/axi_xp.sv \
]
add_files -norecurse -fileset [current_fileset] [list \
    $ROOT/rtl/ldpc_pkg.sv \
    $ROOT/rtl/rom_lutram.sv \
    $ROOT/rtl/rom_dp.sv \
    $ROOT/rtl/asym_rgw_sdp_bram.sv \
    $ROOT/rtl/csr_decoder.sv \
    $ROOT/rtl/input_buffer.sv \
    $ROOT/rtl/ldpc_encoder.sv \
]

set_property include_dirs [list \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/include \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/include \
] [current_fileset]

set_property include_dirs [list \
    $ROOT/.bender/git/checkouts/axi-dbe8c8ba5bb17ff2/include \
    $ROOT/.bender/git/checkouts/common_cells-faa88a3c3739dfb9/include \
] [current_fileset -simset]

set_property verilog_define [list \
    TARGET_FPGA \
    TARGET_SYNTHESIS \
    TARGET_VIVADO \
    TARGET_XILINX \
] [current_fileset]

set_property verilog_define [list \
    TARGET_FPGA \
    TARGET_SYNTHESIS \
    TARGET_VIVADO \
    TARGET_XILINX \
] [current_fileset -simset]

