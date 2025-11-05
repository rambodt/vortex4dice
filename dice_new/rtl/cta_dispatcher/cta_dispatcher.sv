`include "dice_define.vh"

module cta_dispatcher #(
  parameter int unsigned N_CORES = `DICE_NUM_CGRA_CORES
)(
  input  logic                        clk,
  input  logic                        rst_n,

  // ---------------- Host Launch ----------------
  input  logic                        launch_valid,
  output logic                        launch_ready,
  input  dice_pkg::dice_kernel_desc_t launch_desc,

  // ---------------- Dispatcher -> Core Grants ----------------
  output logic              [N_CORES-1:0]          sm_grant_valid,
  input  logic              [N_CORES-1:0]          sm_grant_ready,
  output dice_pkg::dice_cta_desc_t    sm_grant_ctx     [N_CORES],

  // ---------------- Core -> Dispatcher Done ------------------
  input  logic              [N_CORES-1:0]          sm_done_valid,
  output logic              [N_CORES-1:0]          sm_done_ready,
  input  dice_pkg::dice_cta_id_t      sm_done_cta_id   [N_CORES]
);

  import dice_pkg::*;

  // --------------------------------------------------------------------
  // Parameters for credit tracking
  // --------------------------------------------------------------------
  localparam int unsigned MAX_CREDITS = `DICE_NUM_MAX_CTA_PER_CORE;
  localparam int unsigned CREDIT_W    = $clog2(MAX_CREDITS + 1);

  // --------------------------------------------------------------------
  // Internal kernel state
  // --------------------------------------------------------------------
  logic                    kernel_active;
  dice_kernel_desc_t       kdesc_q;

  // 3D counters for next CTA
  logic [DICE_CTA_ID_WIDTH-1:0] cta_x_q, cta_y_q, cta_z_q;
  logic                         issued_all_q;

  // Per-core credits: # of free CTA slots remaining on each core
  logic [CREDIT_W-1:0] credit_q [N_CORES];

  // Total outstanding CTAs across all cores (for quick kernel-drain check)
  logic [$clog2(1<<16)-1:0] outstanding_q;  // big enough for your grids

  // Round-robin pointers
  logic [$clog2(N_CORES)-1:0] rr_ptr_q, rr_ptr_d;
  logic [$clog2(N_CORES)-1:0] done_rr_ptr_q, done_rr_ptr_d;

  // --------------------------------------------------------------------
  // Launch handshake
  // --------------------------------------------------------------------
  assign launch_ready = !kernel_active;

  // --------------------------------------------------------------------
  // CTA enumeration
  // --------------------------------------------------------------------
  function automatic void next_cta_xyz(
    input  dice_kernel_desc_t kd,
    input  logic [DICE_CTA_ID_WIDTH-1:0] x,
    input  logic [DICE_CTA_ID_WIDTH-1:0] y,
    input  logic [DICE_CTA_ID_WIDTH-1:0] z,
    output logic [DICE_CTA_ID_WIDTH-1:0] nx,
    output logic [DICE_CTA_ID_WIDTH-1:0] ny,
    output logic [DICE_CTA_ID_WIDTH-1:0] nz,
    output logic                         was_last
  );
    logic last_x = (x == kd.grid_size.x[DICE_CTA_ID_WIDTH-1:0] - 1);
    logic last_y = (y == kd.grid_size.y[DICE_CTA_ID_WIDTH-1:0] - 1);
    logic last_z = (z == kd.grid_size.z[DICE_CTA_ID_WIDTH-1:0] - 1);

    was_last = last_x && last_y && last_z;
    nx = x; ny = y; nz = z;

    if (!was_last) begin
      if (!last_x) nx = x + 1;
      else begin
        nx = '0;
        if (!last_y) ny = y + 1;
        else begin
          ny = '0;
          nz = z + 1;
        end
      end
    end
  endfunction

  // --------------------------------------------------------------------
  // Pick SM for dispatch (needs READY and CREDIT>0)
  // --------------------------------------------------------------------
  logic have_sm;
  logic [$clog2(N_CORES)-1:0] sel_sm;

  int off;  // static (avoid automatic var dump issues)
  int s;

  always_comb begin
    have_sm = 1'b0;
    sel_sm  = '0;

    for (off = 0; off < N_CORES; off++) begin
      s = (rr_ptr_q + off) % N_CORES;
      if ((credit_q[s] != '0) && sm_grant_ready[s]) begin
        have_sm = 1'b1;
        sel_sm  = s;
        break;
      end
    end

    rr_ptr_d = have_sm ? (sel_sm + 1'b1) : rr_ptr_q;
  end

  // Dispatch ready condition
  logic dispatch_fire;
  assign dispatch_fire = kernel_active && !issued_all_q &&
                       have_sm && sm_grant_ready[sel_sm];

  // --------------------------------------------------------------------
  // Grant output
  // --------------------------------------------------------------------
  always_comb begin
    dice_cta_desc_t ctx;
    ctx.kernel_desc = kdesc_q;
    ctx.cta_id.x    = cta_x_q;
    ctx.cta_id.y    = cta_y_q;
    ctx.cta_id.z    = cta_z_q;

    for (int i = 0; i < N_CORES; i++) begin
      sm_grant_valid[i] = (kernel_active && have_sm && !issued_all_q && (sel_sm == i));
      sm_grant_ctx[i]   = ctx;
    end
  end

  // --------------------------------------------------------------------
  // Completion path — includes CTA ID
  // --------------------------------------------------------------------
  logic have_done;
  logic [$clog2(N_CORES)-1:0] done_sel_sm;
  dice_cta_id_t done_cta_id_sel;

  int off_1; // static (avoid automatic var dump issues)
  int s_1;
  always_comb begin
    have_done       = 1'b0;
    done_sel_sm     = '0;
    done_cta_id_sel = '0;

    for (off_1 = 0; off_1 < N_CORES; off_1++) begin
      s_1 = (done_rr_ptr_q + off_1) % N_CORES;
      if (sm_done_valid[s_1]) begin
        have_done       = 1'b1;
        done_sel_sm     = s_1;
        done_cta_id_sel = sm_done_cta_id[s_1];
        break;
      end
    end

    for (int i = 0; i < N_CORES; i++) begin
      sm_done_ready[i] = have_done && (done_sel_sm == i);
    end

    done_rr_ptr_d = have_done ? (done_sel_sm + 1'b1) : done_rr_ptr_q;
  end

  // --------------------------------------------------------------------
  // State update
  // --------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      kernel_active   <= 1'b0;
      kdesc_q         <= '0;
      cta_x_q         <= '0;
      cta_y_q         <= '0;
      cta_z_q         <= '0;
      issued_all_q    <= 1'b0;
      rr_ptr_q        <= '0;
      done_rr_ptr_q   <= '0;
      outstanding_q   <= '0;
      for (int s = 0; s < N_CORES; s++) begin
        credit_q[s] <= MAX_CREDITS[CREDIT_W-1:0]; // harmless on reset
      end

    end else begin
      // Launch: (re)initialize credits and counters
      if (launch_valid && launch_ready) begin
        kernel_active  <= 1'b1;
        kdesc_q        <= launch_desc;
        cta_x_q        <= '0;
        cta_y_q        <= '0;
        cta_z_q        <= '0;
        issued_all_q   <= 1'b0;
        rr_ptr_q       <= '0;
        done_rr_ptr_q  <= '0;
        outstanding_q  <= '0;
        for (int s = 0; s < N_CORES; s++) begin
          credit_q[s] <= MAX_CREDITS[CREDIT_W-1:0];
        end
      end

      // Dispatch
      // Dispatch: consume credit and move to next CTA only when handshake completes
      if (dispatch_fire) begin
        logic [DICE_CTA_ID_WIDTH-1:0] nx, ny, nz;
        logic was_last;
        next_cta_xyz(kdesc_q, cta_x_q, cta_y_q, cta_z_q, nx, ny, nz, was_last);

        cta_x_q <= nx;
        cta_y_q <= ny;
        cta_z_q <= nz;
        issued_all_q <= was_last;

        credit_q[sel_sm] <= credit_q[sel_sm] - 1'b1;
        outstanding_q    <= outstanding_q + 1'b1;
        rr_ptr_q         <= rr_ptr_d;
      end

      // Completion — return credit and decrease outstanding
      if (have_done) begin
        if (credit_q[done_sel_sm] != MAX_CREDITS[CREDIT_W-1:0])
          credit_q[done_sel_sm] <= credit_q[done_sel_sm] + 1'b1;
        if (dispatch_fire) begin
          // Special case: dispatch and done in same cycle
          // Net effect: outstanding unchanged
          outstanding_q <= outstanding_q;
        end else if (outstanding_q != '0)
          outstanding_q <= outstanding_q - 1'b1;

        done_rr_ptr_q <= done_rr_ptr_d;
      end

      // Kernel retire when all CTAs have been issued and drained
      if (kernel_active && issued_all_q && (outstanding_q == '0))
        kernel_active <= 1'b0;
    end
  end

  // --------------------------------------------------------------------
  // Optional defensive assertions (simulation only)
  // --------------------------------------------------------------------
`ifndef SYNTHESIS
  // Never dispatch if a core has no credits
  always_ff @(posedge clk) if (dispatch_fire) begin
    assert(credit_q[sel_sm] > 0)
      else $error("Dispatch with zero credit on core %0d", sel_sm);
  end

  // Credits never exceed MAX_CREDITS
  generate
    for (genvar i = 0; i < N_CORES; i++) begin : g_credit_chk
      always_ff @(posedge clk) begin
        assert(credit_q[i] <= MAX_CREDITS[CREDIT_W-1:0])
          else $error("Credit overflow on core %0d", i);
      end
    end
  endgenerate
`endif

endmodule
