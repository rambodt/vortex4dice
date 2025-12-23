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