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