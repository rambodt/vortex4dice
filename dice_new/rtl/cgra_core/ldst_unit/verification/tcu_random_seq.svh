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