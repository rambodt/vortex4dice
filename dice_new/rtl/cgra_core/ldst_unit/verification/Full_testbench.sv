// =============================================================================
// UVM Testbench for Temporal Coalescing Unit (TCU)
// =============================================================================

`include "uvm_macros.svh"
import uvm_pkg::*;

// =============================================================================
// INTERFACE
// =============================================================================
interface tcu_if #(
  parameter int CACHE_LINE_SIZE = 32,
  parameter int NUM_MAX_COALESCED_CMDS = CACHE_LINE_SIZE/4,
  parameter int BASE_ADDR_OFFSET = $clog2(CACHE_LINE_SIZE)
)(
  input logic clk,
  input logic rst_n
);

  // Input command signals
  logic        incmd_valid;
  logic [3:0]  incmd_block_id;
  logic [9:0]  incmd_tid;
  logic        incmd_write_enable;
  logic [63:0] incmd_write_data;
  logic [7:0]  incmd_write_mask;
  logic [63:0] incmd_address;
  logic [1:0]  incmd_size;
  logic [6:0]  incmd_ld_dest_reg;
  logic        incmd_ready;

  // Output command signals
  logic        outcmd_valid;
  logic [3:0]  outcmd_block_id;
  logic [9:0]  outcmd_base_tid;
  logic [7:0]  outcmd_tid_bitmap;
  logic        outcmd_write_enable;
  logic [CACHE_LINE_SIZE*8-1:0] outcmd_write_data;
  logic [CACHE_LINE_SIZE-1:0]   outcmd_write_mask;
  logic [63:0] outcmd_address;
  logic [1:0]  outcmd_size;
  logic [6:0]  outcmd_ld_dest_reg;
  logic [NUM_MAX_COALESCED_CMDS-1:0][BASE_ADDR_OFFSET-1:0] outcmd_address_map;
  logic        outcmd_ready;

  // Driver modport
  modport driver_mp (
    input  clk, rst_n,
    input  incmd_ready,
    output incmd_valid, incmd_block_id, incmd_tid, incmd_write_enable,
           incmd_write_data, incmd_write_mask, incmd_address, incmd_size,
           incmd_ld_dest_reg,
    output outcmd_ready,
    input  outcmd_valid, outcmd_block_id, outcmd_base_tid, outcmd_tid_bitmap,
           outcmd_write_enable, outcmd_write_data, outcmd_write_mask,
           outcmd_address, outcmd_size, outcmd_ld_dest_reg, outcmd_address_map
  );

  // Monitor modport (read-only)
  modport monitor_mp (
    input clk, rst_n,
    input incmd_valid, incmd_block_id, incmd_tid, incmd_write_enable,
          incmd_write_data, incmd_write_mask, incmd_address, incmd_size,
          incmd_ld_dest_reg, incmd_ready,
    input outcmd_valid, outcmd_block_id, outcmd_base_tid, outcmd_tid_bitmap,
          outcmd_write_enable, outcmd_write_data, outcmd_write_mask,
          outcmd_address, outcmd_size, outcmd_ld_dest_reg, outcmd_address_map,
          outcmd_ready
  );

endinterface


// =============================================================================
// SEQUENCE ITEM - Input command transaction
// =============================================================================
class tcu_seq_item extends uvm_sequence_item;
  
  rand bit [3:0]  block_id;
  rand bit [9:0]  tid;
  rand bit        write_enable;
  rand bit [63:0] write_data;
  rand bit [7:0]  write_mask;
  rand bit [63:0] address;
  rand bit [1:0]  size;
  rand bit [6:0]  ld_dest_reg;

  // Size constraint (00=1B, 01=2B, 10=4B, 11=8B)
  constraint size_c {
    size inside {2'b00, 2'b01, 2'b10, 2'b11};
  }
  
  // Address alignment based on size
  constraint addr_align_c {
    (size == 2'b01) -> (address[0] == 0);
    (size == 2'b10) -> (address[1:0] == 0);
    (size == 2'b11) -> (address[2:0] == 0);
  }
  
  // Write mask constraint - ensure at least some bytes are writable
  constraint write_mask_c {
    if (write_enable) {
      write_mask != 8'hFF;
      (size == 2'b00) -> (write_mask[0] == 0);
      (size == 2'b01) -> ((write_mask & 8'h03) != 8'h03);
      (size == 2'b10) -> ((write_mask & 8'h0F) != 8'h0F);
      (size == 2'b11) -> ((write_mask & 8'hFF) != 8'hFF);
    }
  }
  
  // Read mask constraint
  constraint read_mask_c {
    (!write_enable) -> (write_mask == 8'hFF);
  }

  `uvm_object_utils_begin(tcu_seq_item)
    `uvm_field_int(block_id,     UVM_ALL_ON)
    `uvm_field_int(tid,          UVM_ALL_ON)
    `uvm_field_int(write_enable, UVM_ALL_ON)
    `uvm_field_int(write_data,   UVM_ALL_ON)
    `uvm_field_int(write_mask,   UVM_ALL_ON)
    `uvm_field_int(address,      UVM_ALL_ON)
    `uvm_field_int(size,         UVM_ALL_ON)
    `uvm_field_int(ld_dest_reg,  UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "tcu_seq_item");
    super.new(name);
  endfunction

  function string convert2string();
    return $sformatf("block_id=%0d tid=%0d we=%0b addr=0x%0h size=%0d data=0x%0h mask=0x%0h ld_dest=%0d",
                     block_id, tid, write_enable, address, size, write_data, write_mask, ld_dest_reg);
  endfunction

endclass


// =============================================================================
// OUTPUT ITEM - Coalesced output transaction
// =============================================================================
class tcu_out_item extends uvm_sequence_item;
  
  localparam int CACHE_LINE_SIZE = 32;
  localparam int N_MAX_CMDS      = CACHE_LINE_SIZE/4;
  localparam int BASE_ADDR_OFF   = $clog2(CACHE_LINE_SIZE);

  bit [3:0]  block_id;
  bit [9:0]  base_tid;
  bit [7:0]  tid_bitmap;
  bit        write_enable;
  bit [CACHE_LINE_SIZE*8-1:0] write_data;
  bit [CACHE_LINE_SIZE-1:0]   write_mask;
  bit [63:0] address;
  bit [1:0]  size;
  bit [6:0]  ld_dest_reg;
  bit [N_MAX_CMDS-1:0][BASE_ADDR_OFF-1:0] address_map;

  `uvm_object_utils_begin(tcu_out_item)
    `uvm_field_int(block_id,     UVM_ALL_ON)
    `uvm_field_int(base_tid,     UVM_ALL_ON)
    `uvm_field_int(tid_bitmap,   UVM_ALL_ON)
    `uvm_field_int(write_enable, UVM_ALL_ON)
    `uvm_field_int(write_data,   UVM_ALL_ON)
    `uvm_field_int(write_mask,   UVM_ALL_ON)
    `uvm_field_int(address,      UVM_ALL_ON)
    `uvm_field_int(size,         UVM_ALL_ON)
    `uvm_field_int(ld_dest_reg,  UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "tcu_out_item");
    super.new(name);
  endfunction

  function string convert2string();
    return $sformatf("block_id=%0d base_tid=%0d bitmap=0x%0h we=%0b addr=0x%0h",
                     block_id, base_tid, tid_bitmap, write_enable, address);
  endfunction

endclass


// =============================================================================
// DRIVER - Converts transactions to pin activity
// =============================================================================
class tcu_driver extends uvm_driver #(tcu_seq_item);
  `uvm_component_utils(tcu_driver)

  virtual tcu_if.driver_mp vif;

  function new(string name = "tcu_driver", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual tcu_if.driver_mp)::get(this, "", "vif", vif)) begin
      `uvm_fatal("NOVIF", "Virtual interface not set for tcu_driver")
    end
  endfunction

  task run_phase(uvm_phase phase);
    tcu_seq_item tr;

    // Initialize outputs
    vif.incmd_valid      <= 0;
    vif.incmd_block_id   <= 0;
    vif.incmd_tid        <= 0;
    vif.incmd_write_enable <= 0;
    vif.incmd_write_data <= 0;
    vif.incmd_write_mask <= 8'hFF;
    vif.incmd_address    <= 0;
    vif.incmd_size       <= 0;
    vif.incmd_ld_dest_reg <= 0;
    vif.outcmd_ready     <= 1;

    // Wait for reset
    wait(vif.rst_n === 0);
    wait(vif.rst_n === 1);
    repeat(2) @(posedge vif.clk);

    // Main driver loop
    forever begin
      seq_item_port.get_next_item(tr);
      `uvm_info("DRIVER", $sformatf("Driving: %s", tr.convert2string()), UVM_MEDIUM)
      drive_transaction(tr);
      seq_item_port.item_done();
    end
  endtask

  // Drive transaction with valid/ready handshake
  task drive_transaction(tcu_seq_item tr);
    @(posedge vif.clk);
    
    vif.incmd_block_id     <= tr.block_id;
    vif.incmd_tid          <= tr.tid;
    vif.incmd_write_enable <= tr.write_enable;
    vif.incmd_write_data   <= tr.write_data;
    vif.incmd_write_mask   <= tr.write_mask;
    vif.incmd_address      <= tr.address;
    vif.incmd_size         <= tr.size;
    vif.incmd_ld_dest_reg  <= tr.ld_dest_reg;
    vif.incmd_valid        <= 1'b1;

    // Wait for handshake
    do begin
      @(posedge vif.clk);
    end while (!vif.incmd_ready);

    vif.incmd_valid <= 1'b0;
  endtask

endclass


// =============================================================================
// MONITOR - Observes DUT interfaces
// =============================================================================
class tcu_monitor extends uvm_component;
  `uvm_component_utils(tcu_monitor)

  virtual tcu_if.monitor_mp vif;

  uvm_analysis_port #(tcu_seq_item) in_ap;
  uvm_analysis_port #(tcu_out_item) out_ap;

  function new(string name = "tcu_monitor", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    in_ap  = new("in_ap",  this);
    out_ap = new("out_ap", this);
    if (!uvm_config_db#(virtual tcu_if.monitor_mp)::get(this, "", "vif", vif)) begin
      `uvm_fatal("NOVIF", "Virtual interface not set for tcu_monitor")
    end
  endfunction

  task run_phase(uvm_phase phase);
    fork
      monitor_input();
      monitor_output();
    join
  endtask

  // Monitor input commands
  task monitor_input();
    tcu_seq_item tr;
    forever begin
      @(posedge vif.clk);
      if (vif.incmd_valid && vif.incmd_ready) begin
        tr = tcu_seq_item::type_id::create("in_tr");
        tr.block_id     = vif.incmd_block_id;
        tr.tid          = vif.incmd_tid;
        tr.write_enable = vif.incmd_write_enable;
        tr.write_data   = vif.incmd_write_data;
        tr.write_mask   = vif.incmd_write_mask;
        tr.address      = vif.incmd_address;
        tr.size         = vif.incmd_size;
        tr.ld_dest_reg  = vif.incmd_ld_dest_reg;
        `uvm_info("MON_IN", $sformatf("Captured input: %s", tr.convert2string()), UVM_HIGH)
        in_ap.write(tr);
      end
    end
  endtask

  // Monitor output commands
  task monitor_output();
    tcu_out_item tr;
    forever begin
      @(posedge vif.clk);
      if (vif.outcmd_valid && vif.outcmd_ready) begin
        tr = tcu_out_item::type_id::create("out_tr");
        tr.block_id     = vif.outcmd_block_id;
        tr.base_tid     = vif.outcmd_base_tid;
        tr.tid_bitmap   = vif.outcmd_tid_bitmap;
        tr.write_enable = vif.outcmd_write_enable;
        tr.write_data   = vif.outcmd_write_data;
        tr.write_mask   = vif.outcmd_write_mask;
        tr.address      = vif.outcmd_address;
        tr.size         = vif.outcmd_size;
        tr.ld_dest_reg  = vif.outcmd_ld_dest_reg;
        tr.address_map  = vif.outcmd_address_map;
        `uvm_info("MON_OUT", $sformatf("Captured output: %s", tr.convert2string()), UVM_HIGH)
        out_ap.write(tr);
      end
    end
  endtask

endclass


// =============================================================================
// SEQUENCER
// =============================================================================
class tcu_sequencer extends uvm_sequencer #(tcu_seq_item);
  `uvm_component_utils(tcu_sequencer)

  function new(string name = "tcu_sequencer", uvm_component parent = null);
    super.new(name, parent);
  endfunction
endclass


// =============================================================================
// AGENT - Contains driver, monitor, sequencer
// =============================================================================
class tcu_agent extends uvm_agent;
  `uvm_component_utils(tcu_agent)

  tcu_driver    drv;
  tcu_monitor   mon;
  tcu_sequencer sqr;
  
  bit is_active = 1;

  function new(string name = "tcu_agent", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    mon = tcu_monitor::type_id::create("mon", this);
    if (is_active) begin
      drv = tcu_driver::type_id::create("drv", this);
      sqr = tcu_sequencer::type_id::create("sqr", this);
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (is_active) begin
      drv.seq_item_port.connect(sqr.seq_item_export);
    end
  endfunction

endclass


// =============================================================================
// SCOREBOARD
// =============================================================================
`uvm_analysis_imp_decl(_in)
`uvm_analysis_imp_decl(_out)

class tcu_scoreboard extends uvm_component;
  `uvm_component_utils(tcu_scoreboard)

  uvm_analysis_imp_in  #(tcu_seq_item, tcu_scoreboard) in_imp;
  uvm_analysis_imp_out #(tcu_out_item, tcu_scoreboard) out_imp;

  // Reference model state
  tcu_out_item expected_q[$];
  tcu_out_item actual_outputs[$];
  
  bit          buffer_valid;
  bit [63:0]   buffer_base_addr;
  bit [3:0]    buffer_block_id;
  bit [9:0]    buffer_base_tid;
  bit [7:0]    buffer_tid_bitmap;
  bit          buffer_write_enable;
  bit [6:0]    buffer_ld_dest_reg;
  bit [255:0]  buffer_write_data;
  bit [31:0]   buffer_write_mask;
  bit [1:0]    buffer_size;
  
  // Statistics
  int unsigned num_inputs;
  int unsigned num_outputs;
  int unsigned num_matches;
  int unsigned num_mismatches;

  localparam int CACHE_LINE_SIZE = 32;
  localparam int BASE_ADDR_OFFSET = $clog2(CACHE_LINE_SIZE);

  function new(string name = "tcu_scoreboard", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    in_imp  = new("in_imp",  this);
    out_imp = new("out_imp", this);
    buffer_valid = 0;
    num_inputs = 0;
    num_outputs = 0;
    num_matches = 0;
    num_mismatches = 0;
  endfunction

  // Process input transactions
  function void write_in(tcu_seq_item tr);
    bit [63:0] in_base_addr;
    bit [9:0]  in_base_tid;
    bit        can_coalesce;
    
    num_inputs++;
    `uvm_info("SCB_IN", $sformatf("Received input #%0d: %s", num_inputs, tr.convert2string()), UVM_MEDIUM)
    
    in_base_addr = {tr.address[63:BASE_ADDR_OFFSET], {BASE_ADDR_OFFSET{1'b0}}};
    in_base_tid = {tr.tid[9:3], 3'b0};
    
    can_coalesce = buffer_valid &&
                   (buffer_base_addr == in_base_addr) &&
                   (buffer_block_id == tr.block_id) &&
                   (buffer_base_tid == in_base_tid) &&
                   (buffer_write_enable == tr.write_enable) &&
                   (buffer_ld_dest_reg == tr.ld_dest_reg || tr.write_enable);
    
    if (!buffer_valid) begin
      init_buffer(tr, in_base_addr, in_base_tid);
      `uvm_info("SCB_IN", "Started new coalescing buffer", UVM_HIGH)
    end
    else if (can_coalesce) begin
      merge_into_buffer(tr);
      `uvm_info("SCB_IN", "Merged into existing buffer", UVM_HIGH)
    end
    else begin
      flush_buffer();
      init_buffer(tr, in_base_addr, in_base_tid);
      `uvm_info("SCB_IN", "Flushed buffer, started new", UVM_HIGH)
    end
  endfunction

  // Process output transactions with sanity checking
  function void write_out(tcu_out_item tr);
    num_outputs++;
    `uvm_info("SCB_OUT", $sformatf("Received output #%0d: %s", num_outputs, tr.convert2string()), UVM_MEDIUM)
    actual_outputs.push_back(tr);
    check_output_sanity(tr);
  endfunction
  
  // Sanity checks on output
  function void check_output_sanity(tcu_out_item tr);
    if (tr.tid_bitmap == 0) begin
      `uvm_error("SCB", "Output has empty tid_bitmap")
      num_mismatches++;
      return;
    end
    
    if (tr.address[4:0] != 0) begin
      `uvm_error("SCB", $sformatf("Output address 0x%h is not cache-line aligned", tr.address))
      num_mismatches++;
      return;
    end
    
    if (tr.write_enable && tr.write_mask == '1) begin
      `uvm_warning("SCB", "Write output has all bytes masked")
    end
    
    num_matches++;
    `uvm_info("SCB", "Output passed sanity checks", UVM_HIGH)
  endfunction

  // Helper functions
  function void init_buffer(tcu_seq_item tr, bit [63:0] base_addr, bit [9:0] base_tid);
    bit [4:0] addr_offset;
    bit [2:0] tid_offset;
    
    buffer_valid        = 1;
    buffer_base_addr    = base_addr;
    buffer_block_id     = tr.block_id;
    buffer_base_tid     = base_tid;
    buffer_write_enable = tr.write_enable;
    buffer_ld_dest_reg  = tr.ld_dest_reg;
    buffer_size         = tr.size;
    buffer_write_mask   = '1;
    buffer_write_data   = '0;
    
    tid_offset = tr.tid[2:0];
    buffer_tid_bitmap = (1 << tid_offset);
    
    if (tr.write_enable) begin
      addr_offset = tr.address[4:0];
      apply_write_to_buffer(tr, addr_offset);
    end
  endfunction

  function void merge_into_buffer(tcu_seq_item tr);
    bit [4:0] addr_offset;
    bit [2:0] tid_offset;
    
    tid_offset = tr.tid[2:0];
    buffer_tid_bitmap |= (1 << tid_offset);
    
    if (tr.write_enable) begin
      addr_offset = tr.address[4:0];
      apply_write_to_buffer(tr, addr_offset);
    end
  endfunction

  function void apply_write_to_buffer(tcu_seq_item tr, bit [4:0] addr_offset);
    int actual_size;
    
    case (tr.size)
      2'b00: actual_size = 1;
      2'b01: actual_size = 2;
      2'b10: actual_size = 4;
      2'b11: actual_size = 8;
    endcase
    
    for (int i = 0; i < actual_size && i < 8; i++) begin
      if (!tr.write_mask[i]) begin
        buffer_write_data[(addr_offset + i) * 8 +: 8] = tr.write_data[i * 8 +: 8];
        buffer_write_mask[addr_offset + i] = 0;
      end
    end
  endfunction

  function void flush_buffer();
    tcu_out_item exp;
    
    if (!buffer_valid) return;
    
    exp = tcu_out_item::type_id::create("exp");
    exp.block_id     = buffer_block_id;
    exp.base_tid     = buffer_base_tid;
    exp.tid_bitmap   = buffer_tid_bitmap;
    exp.write_enable = buffer_write_enable;
    exp.write_data   = buffer_write_data;
    exp.write_mask   = buffer_write_mask;
    exp.address      = buffer_base_addr;
    exp.size         = buffer_size;
    exp.ld_dest_reg  = buffer_ld_dest_reg;
    
    expected_q.push_back(exp);
    buffer_valid = 0;
    `uvm_info("SCB", $sformatf("Pushed expected output: %s", exp.convert2string()), UVM_HIGH)
  endfunction

  function bit compare_outputs(tcu_out_item exp, tcu_out_item act);
    bit match = 1;
    
    if (exp.block_id != act.block_id) begin
      `uvm_info("SCB", $sformatf("block_id mismatch: exp=%0h act=%0h", exp.block_id, act.block_id), UVM_LOW)
      match = 0;
    end
    if (exp.base_tid != act.base_tid) begin
      `uvm_info("SCB", $sformatf("base_tid mismatch: exp=%0h act=%0h", exp.base_tid, act.base_tid), UVM_LOW)
      match = 0;
    end
    if (exp.tid_bitmap != act.tid_bitmap) begin
      `uvm_info("SCB", $sformatf("tid_bitmap mismatch: exp=%0h act=%0h", exp.tid_bitmap, act.tid_bitmap), UVM_LOW)
      match = 0;
    end
    if (exp.address != act.address) begin
      `uvm_info("SCB", $sformatf("address mismatch: exp=%0h act=%0h", exp.address, act.address), UVM_LOW)
      match = 0;
    end
    if (exp.write_enable != act.write_enable) begin
      `uvm_info("SCB", $sformatf("write_enable mismatch: exp=%0h act=%0h", exp.write_enable, act.write_enable), UVM_LOW)
      match = 0;
    end
    
    return match;
  endfunction

  function void report_phase(uvm_phase phase);
    int total_coalesced_tids;
    
    super.report_phase(phase);
    
    total_coalesced_tids = 0;
    foreach (actual_outputs[i]) begin
      for (int b = 0; b < 8; b++) begin
        if (actual_outputs[i].tid_bitmap[b]) total_coalesced_tids++;
      end
    end
    
    `uvm_info("SCB", "========== SCOREBOARD SUMMARY ==========", UVM_LOW)
    `uvm_info("SCB", $sformatf("  Total Inputs:          %0d", num_inputs), UVM_LOW)
    `uvm_info("SCB", $sformatf("  Total Outputs:         %0d", num_outputs), UVM_LOW)
    `uvm_info("SCB", $sformatf("  Coalescing Ratio:      %.2f:1", 
                               num_outputs > 0 ? real'(total_coalesced_tids)/real'(num_outputs) : 0), UVM_LOW)
    `uvm_info("SCB", $sformatf("  Sanity Checks Passed:  %0d", num_matches), UVM_LOW)
    `uvm_info("SCB", $sformatf("  Sanity Checks Failed:  %0d", num_mismatches), UVM_LOW)
    `uvm_info("SCB", "=========================================", UVM_LOW)
    
    if (num_mismatches > 0) begin
      `uvm_error("SCB", $sformatf("TEST FAILED: %0d sanity check failures", num_mismatches))
    end
    else if (num_outputs == 0 && num_inputs > 0) begin
      `uvm_error("SCB", "TEST FAILED: No outputs received despite inputs!")
    end
    else begin
      `uvm_info("SCB", "TEST PASSED - All sanity checks passed", UVM_LOW)
    end
  endfunction

endclass


// =============================================================================
// ENVIRONMENT
// =============================================================================
class tcu_env extends uvm_env;
  `uvm_component_utils(tcu_env)

  tcu_agent      agt;
  tcu_scoreboard scb;

  function new(string name = "tcu_env", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    agt = tcu_agent::type_id::create("agt", this);
    scb = tcu_scoreboard::type_id::create("scb", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    agt.mon.in_ap.connect(scb.in_imp);
    agt.mon.out_ap.connect(scb.out_imp);
  endfunction

endclass


// =============================================================================
// SEQUENCES
// =============================================================================

// Random sequence
class tcu_random_seq extends uvm_sequence #(tcu_seq_item);
  `uvm_object_utils(tcu_random_seq)
  
  int unsigned num_items = 20;

  function new(string name = "tcu_random_seq");
    super.new(name);
  endfunction

  task body();
    tcu_seq_item tr;
    `uvm_info("SEQ", $sformatf("Starting random sequence with %0d items", num_items), UVM_MEDIUM)
    
    repeat (num_items) begin
      tr = tcu_seq_item::type_id::create("tr");
      start_item(tr);
      if (!tr.randomize()) `uvm_error("SEQ", "Randomization failed!")
      finish_item(tr);
    end
    
    `uvm_info("SEQ", "Random sequence complete", UVM_MEDIUM)
  endtask
endclass


// Coalescing test sequence
class tcu_coalesce_seq extends uvm_sequence #(tcu_seq_item);
  `uvm_object_utils(tcu_coalesce_seq)

  function new(string name = "tcu_coalesce_seq");
    super.new(name);
  endfunction

  task body();
    tcu_seq_item tr;
    bit [63:0] base_addr;
    
    `uvm_info("SEQ", "Starting coalescing test sequence", UVM_MEDIUM)
    
    // Test 1: 4 writes to same cache line
    `uvm_info("SEQ", "Test 1: 4 writes to same cache line", UVM_LOW)
    base_addr = 64'h1000;
    
    for (int i = 0; i < 4; i++) begin
      tr = tcu_seq_item::type_id::create("tr");
      start_item(tr);
      tr.block_id     = 4'h1;
      tr.tid          = 10'(i);
      tr.write_enable = 1;
      tr.address      = base_addr + (i * 4);
      tr.size         = 2'b10;
      tr.write_data   = 64'hDEADBEEF_00000000 | i;
      tr.write_mask   = 8'h00;
      tr.ld_dest_reg  = 7'h0;
      finish_item(tr);
    end
    
    #100ns;
    
    // Test 2: Write to different cache line
    `uvm_info("SEQ", "Test 2: Write to different cache line", UVM_LOW)
    tr = tcu_seq_item::type_id::create("tr");
    start_item(tr);
    tr.block_id     = 4'h1;
    tr.tid          = 10'h4;
    tr.write_enable = 1;
    tr.address      = 64'h2000;
    tr.size         = 2'b10;
    tr.write_data   = 64'hCAFEBABE;
    tr.write_mask   = 8'h00;
    tr.ld_dest_reg  = 7'h0;
    finish_item(tr);
    
    // Test 3: 4 reads from same cache line
    `uvm_info("SEQ", "Test 3: 4 reads from same cache line", UVM_LOW)
    base_addr = 64'h3000;
    
    for (int i = 0; i < 4; i++) begin
      tr = tcu_seq_item::type_id::create("tr");
      start_item(tr);
      tr.block_id     = 4'h2;
      tr.tid          = 10'(8 + i);
      tr.write_enable = 0;
      tr.address      = base_addr + (i * 4);
      tr.size         = 2'b10;
      tr.write_data   = 64'h0;
      tr.write_mask   = 8'hFF;
      tr.ld_dest_reg  = 7'(10 + i);
      finish_item(tr);
    end
    
    `uvm_info("SEQ", "Coalescing test sequence complete", UVM_MEDIUM)
  endtask
endclass


// Non-coalescing test sequence
class tcu_no_coalesce_seq extends uvm_sequence #(tcu_seq_item);
  `uvm_object_utils(tcu_no_coalesce_seq)

  function new(string name = "tcu_no_coalesce_seq");
    super.new(name);
  endfunction

  task body();
    tcu_seq_item tr;
    
    `uvm_info("SEQ", "Starting non-coalescing test sequence", UVM_MEDIUM)
    
    // Command 1
    tr = tcu_seq_item::type_id::create("tr");
    start_item(tr);
    tr.block_id = 4'h1; tr.tid = 10'h0; tr.write_enable = 1;
    tr.address = 64'h1000; tr.size = 2'b10;
    tr.write_data = 64'h11111111; tr.write_mask = 8'h00; tr.ld_dest_reg = 7'h0;
    finish_item(tr);
    
    // Command 2 - Different block_id
    tr = tcu_seq_item::type_id::create("tr");
    start_item(tr);
    tr.block_id = 4'h2; tr.tid = 10'h1; tr.write_enable = 1;
    tr.address = 64'h1004; tr.size = 2'b10;
    tr.write_data = 64'h22222222; tr.write_mask = 8'h00; tr.ld_dest_reg = 7'h0;
    finish_item(tr);
    
    // Command 3 - Different write_enable
    tr = tcu_seq_item::type_id::create("tr");
    start_item(tr);
    tr.block_id = 4'h2; tr.tid = 10'h2; tr.write_enable = 0;
    tr.address = 64'h1008; tr.size = 2'b10;
    tr.write_data = 64'h0; tr.write_mask = 8'hFF; tr.ld_dest_reg = 7'h5;
    finish_item(tr);
    
    // Command 4 - Different base TID chunk
    tr = tcu_seq_item::type_id::create("tr");
    start_item(tr);
    tr.block_id = 4'h2; tr.tid = 10'h10; tr.write_enable = 0;
    tr.address = 64'h100C; tr.size = 2'b10;
    tr.write_data = 64'h0; tr.write_mask = 8'hFF; tr.ld_dest_reg = 7'h5;
    finish_item(tr);
    
    `uvm_info("SEQ", "Non-coalescing test sequence complete", UVM_MEDIUM)
  endtask
endclass


// =============================================================================
// TEST
// =============================================================================
class tcu_base_test extends uvm_test;
  `uvm_component_utils(tcu_base_test)

  tcu_env env;
  int log_file;

  function new(string name = "tcu_base_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = tcu_env::type_id::create("env", this);
  endfunction
  
  // Configure logging
  function void start_of_simulation_phase(uvm_phase phase);
    super.start_of_simulation_phase(phase);
    
    log_file = $fopen("uvm_test.log", "w");
    if (log_file) begin
      set_report_default_file_hier(log_file);
      set_report_severity_action_hier(UVM_INFO,    UVM_DISPLAY | UVM_LOG);
      set_report_severity_action_hier(UVM_WARNING, UVM_DISPLAY | UVM_LOG);
      set_report_severity_action_hier(UVM_ERROR,   UVM_DISPLAY | UVM_LOG | UVM_COUNT);
      set_report_severity_action_hier(UVM_FATAL,   UVM_DISPLAY | UVM_LOG | UVM_EXIT);
      `uvm_info("TEST", "Logging to: uvm_test.log", UVM_LOW)
    end
    
    `uvm_info("TEST", "========================================", UVM_LOW)
    `uvm_info("TEST", "   TCU UVM TESTBENCH STARTING", UVM_LOW)
    `uvm_info("TEST", "========================================", UVM_LOW)
  endfunction
  
  function void final_phase(uvm_phase phase);
    super.final_phase(phase);
    if (log_file) $fclose(log_file);
  endfunction

  task run_phase(uvm_phase phase);
    tcu_random_seq      rand_seq;
    tcu_coalesce_seq    coal_seq;
    tcu_no_coalesce_seq no_coal_seq;
    
    phase.raise_objection(this, "Starting test");
    
    `uvm_info("TEST", "========== TEST STARTING ==========", UVM_LOW)
    
    // Run coalescing sequence
    coal_seq = tcu_coalesce_seq::type_id::create("coal_seq");
    coal_seq.start(env.agt.sqr);
    #200ns;
    
    // Run non-coalescing sequence
    no_coal_seq = tcu_no_coalesce_seq::type_id::create("no_coal_seq");
    no_coal_seq.start(env.agt.sqr);
    #200ns;
    
    // Run random traffic
    rand_seq = tcu_random_seq::type_id::create("rand_seq");
    rand_seq.num_items = 50;
    rand_seq.start(env.agt.sqr);
    
    #500ns;
    
    `uvm_info("TEST", "========== TEST COMPLETE ==========", UVM_LOW)
    
    phase.drop_objection(this, "Test complete");
  endtask
  
  function void report_phase(uvm_phase phase);
    uvm_report_server server;
    int errors, warnings, fatals;
    
    super.report_phase(phase);
    
    server = uvm_report_server::get_server();
    errors   = server.get_severity_count(UVM_ERROR);
    warnings = server.get_severity_count(UVM_WARNING);
    fatals   = server.get_severity_count(UVM_FATAL);
    
    `uvm_info("TEST", "", UVM_LOW)
    `uvm_info("TEST", "╔══════════════════════════════════════════════════════╗", UVM_LOW)
    `uvm_info("TEST", "║            FINAL TEST SUMMARY                        ║", UVM_LOW)
    `uvm_info("TEST", "╠══════════════════════════════════════════════════════╣", UVM_LOW)
    `uvm_info("TEST", $sformatf("║  Errors:   %4d                                      ║", errors), UVM_LOW)
    `uvm_info("TEST", $sformatf("║  Warnings: %4d                                      ║", warnings), UVM_LOW)
    `uvm_info("TEST", $sformatf("║  Fatals:   %4d                                      ║", fatals), UVM_LOW)
    `uvm_info("TEST", "╠══════════════════════════════════════════════════════╣", UVM_LOW)
    
    if (errors == 0 && fatals == 0)
      `uvm_info("TEST", "║  *** TEST PASSED ***                                 ║", UVM_LOW)
    else
      `uvm_info("TEST", "║  *** TEST FAILED ***                                 ║", UVM_LOW)
    
    `uvm_info("TEST", "╚══════════════════════════════════════════════════════╝", UVM_LOW)
    `uvm_info("TEST", "", UVM_LOW)
    `uvm_info("TEST", "Log file: uvm_test.log", UVM_LOW)
  endfunction

endclass


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