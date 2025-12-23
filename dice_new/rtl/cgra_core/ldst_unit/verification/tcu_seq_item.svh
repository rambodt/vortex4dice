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