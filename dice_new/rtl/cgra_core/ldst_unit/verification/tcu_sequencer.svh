// =============================================================================
// SEQUENCER
// =============================================================================
class tcu_sequencer extends uvm_sequencer #(tcu_seq_item);
  `uvm_component_utils(tcu_sequencer)

  function new(string name = "tcu_sequencer", uvm_component parent = null);
    super.new(name, parent);
  endfunction
endclass