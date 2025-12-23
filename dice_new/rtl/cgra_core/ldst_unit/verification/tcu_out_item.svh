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