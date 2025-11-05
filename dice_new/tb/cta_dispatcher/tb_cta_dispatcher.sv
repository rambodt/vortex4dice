`timescale 1ns/1ps
`include "dice_define.vh"
`include "dice_pkg.sv"

module tb_cta_dispatcher;

  import dice_pkg::*;

  // --------------------------------------------------------------------------
  // Parameters / DUT setup
  // --------------------------------------------------------------------------
  localparam int N_CORES = 4;

  logic clk;
  logic rst_n;

  // DUT <-> Host interface
  logic                    launch_valid;
  logic                    launch_ready;
  dice_kernel_desc_t       launch_desc;

  // DUT <-> CGRA cores interface
  logic             [N_CORES-1:0]       sm_grant_valid ;
  logic             [N_CORES-1:0]       sm_grant_ready ;
  dice_cta_desc_t          sm_grant_ctx   [N_CORES];

  logic             [N_CORES-1:0]       sm_done_valid  ;
  logic             [N_CORES-1:0]       sm_done_ready  ;
  dice_cta_id_t            sm_done_cta_id [N_CORES];

  // --------------------------------------------------------------------------
  // DUT (CTA Dispatcher)
  // --------------------------------------------------------------------------
  cta_dispatcher #(
    .N_CORES(N_CORES)
  ) dut (
    .clk(clk),
    .rst_n(rst_n),

    // Host
    .launch_valid(launch_valid),
    .launch_ready(launch_ready),
    .launch_desc(launch_desc),

    // To cores
    .sm_grant_valid(sm_grant_valid),
    .sm_grant_ready(sm_grant_ready),
    .sm_grant_ctx(sm_grant_ctx),

    // From cores
    .sm_done_valid(sm_done_valid),
    .sm_done_ready(sm_done_ready),
    .sm_done_cta_id(sm_done_cta_id)
  );

  // --------------------------------------------------------------------------
  // Dummy CGRA cores (behavioral SMs)
  // --------------------------------------------------------------------------
  for (genvar i = 0; i < N_CORES; i++) begin : g_cores
    cgra_core_dummy_model #(
      .CORE_ID(i)
    ) u_core (
      .clk(clk),
      .rst_n(rst_n),
      .sm_grant_valid(sm_grant_valid[i]),
      .sm_grant_ready(sm_grant_ready[i]),
      .sm_grant_ctx(sm_grant_ctx[i]),
      .sm_done_valid(sm_done_valid[i]),
      .sm_done_ready(sm_done_ready[i]),
      .sm_done_cta_id(sm_done_cta_id[i])
    );
  end

  // --------------------------------------------------------------------------
  // Clock and reset
  // --------------------------------------------------------------------------
  initial clk = 0;
  always #5 clk = ~clk; // 100 MHz

  initial begin
    rst_n = 0;
    launch_valid = 0;
    repeat (10) @(negedge clk);
    rst_n = 1;
  end

  // --------------------------------------------------------------------------
  // Stimulus: single kernel launch
  // --------------------------------------------------------------------------
  initial begin : stimulus
    wait(rst_n);
    repeat (5) @(negedge clk);

    // Create a kernel descriptor with more CTAs than can fit simultaneously
    // Suppose each core supports 4 CTAs max -> total 16 in flight max
    // Launch grid = 4x3x2 = 24 CTAs to force reuse of credits
    launch_desc = '0;
    launch_desc.kernel_id = 8'h01;
    launch_desc.grid_size = '{x: 4, y: 4, z: 4}; // 64 CTAs total
    launch_desc.cta_size  = '{x: 128, y: 1, z: 1};
    launch_desc.smem_per_cta = '0;
    launch_desc.start_pc  = 32'h1000;
    launch_desc.arg_ptr   = 32'h2000;

    $display("[%0t] === Launching kernel ===", $time);
    launch_valid = 1'b1;
    wait(launch_ready);
    @(negedge clk);
    launch_valid = 1'b0;

    // Wait until the dispatcher fully completes kernel
    wait_kernel_done();

    $display("[%0t] === Kernel finished successfully ===", $time);
    repeat (20) @(negedge clk);
    $finish;
  end

  // --------------------------------------------------------------------------
  // Task: wait for kernel completion
  // --------------------------------------------------------------------------
  task wait_kernel_done();
    forever begin
      @(negedge clk);
      if (!dut.kernel_active) begin
        $display("[%0t] Kernel active=0 (done)", $time);
        break;
      end
    end
  endtask

  // --------------------------------------------------------------------------
  // Periodic monitor
  // --------------------------------------------------------------------------
  always_ff @(negedge clk)
    if (dut.dispatch_fire)
      $display("[%0t][MON] Issuing CTA (%0d,%0d,%0d)",
               $time, dut.cta_x_q, dut.cta_y_q, dut.cta_z_q);

  // --------------------------------------------------------------------------
  // Waveform dump (FSDB)
  // --------------------------------------------------------------------------
  initial begin
    $fsdbDumpfile("tb_cta_dispatcher.fsdb");
    $fsdbDumpvars(0, tb_cta_dispatcher);
  end

endmodule
