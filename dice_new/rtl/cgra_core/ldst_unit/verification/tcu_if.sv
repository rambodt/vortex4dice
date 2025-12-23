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