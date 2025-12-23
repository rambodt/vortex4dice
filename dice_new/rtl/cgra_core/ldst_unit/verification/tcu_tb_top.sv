`include "uvm_macros.svh"
import uvm_pkg::*;
import tcu_pkg::*;

// =============================================================================
// TOP-LEVEL TESTBENCH
// =============================================================================
module tcu_tb_top;

  localparam int CACHE_LINE_SIZE = 32;
  localparam int N_MAX_CMDS      = CACHE_LINE_SIZE/4;
  localparam int BASE_ADDR_OFF   = $clog2(CACHE_LINE_SIZE);

  logic clk;
  logic rst_n;

  // Interface
  tcu_if #(
    .CACHE_LINE_SIZE(CACHE_LINE_SIZE),
    .NUM_MAX_COALESCED_CMDS(N_MAX_CMDS),
    .BASE_ADDR_OFFSET(BASE_ADDR_OFF)
  ) tcu_vif (.clk(clk), .rst_n(rst_n));

  // DUT
  temporal_coalescing_unit #(
    .cache_line_size(CACHE_LINE_SIZE),
    .number_of_max_coalesced_commands(N_MAX_CMDS),
    .base_address_offset(BASE_ADDR_OFF)
  ) dut (
    .clk              (clk),
    .rst_n            (rst_n),
    .incmd_valid      (tcu_vif.incmd_valid),
    .incmd_block_id   (tcu_vif.incmd_block_id),
    .incmd_tid        (tcu_vif.incmd_tid),
    .incmd_write_enable(tcu_vif.incmd_write_enable),
    .incmd_write_data (tcu_vif.incmd_write_data),
    .incmd_write_mask (tcu_vif.incmd_write_mask),
    .incmd_address    (tcu_vif.incmd_address),
    .incmd_size       (tcu_vif.incmd_size),
    .incmd_ld_dest_reg(tcu_vif.incmd_ld_dest_reg),
    .incmd_ready      (tcu_vif.incmd_ready),
    .outcmd_valid     (tcu_vif.outcmd_valid),
    .outcmd_block_id  (tcu_vif.outcmd_block_id),
    .outcmd_base_tid  (tcu_vif.outcmd_base_tid),
    .outcmd_tid_bitmap(tcu_vif.outcmd_tid_bitmap),
    .outcmd_write_enable(tcu_vif.outcmd_write_enable),
    .outcmd_write_data(tcu_vif.outcmd_write_data),
    .outcmd_write_mask(tcu_vif.outcmd_write_mask),
    .outcmd_address   (tcu_vif.outcmd_address),
    .outcmd_size      (tcu_vif.outcmd_size),
    .outcmd_ld_dest_reg(tcu_vif.outcmd_ld_dest_reg),
    .outcmd_address_map(tcu_vif.outcmd_address_map),
    .outcmd_ready     (tcu_vif.outcmd_ready)
  );

  // Clock generation
  initial begin
    clk = 0;
    forever #5ns clk = ~clk;
  end

  // Reset generation
  initial begin
    rst_n = 0;
    #100ns;
    rst_n = 1;
    `uvm_info("TB_TOP", "Reset released", UVM_LOW)
  end

  // UVM configuration
  initial begin
    uvm_config_db#(virtual tcu_if.driver_mp)::set(
      null, "uvm_test_top.env.agt.drv", "vif", tcu_vif);
    uvm_config_db#(virtual tcu_if.monitor_mp)::set(
      null, "uvm_test_top.env.agt.mon", "vif", tcu_vif);
    run_test("tcu_base_test");
  end

  // Waveform dump
  initial begin
    $dumpfile("tcu_tb.vcd");
    $dumpvars(0, tcu_tb_top);
  end

endmodule