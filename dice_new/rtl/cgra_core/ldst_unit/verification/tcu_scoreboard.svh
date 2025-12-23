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