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