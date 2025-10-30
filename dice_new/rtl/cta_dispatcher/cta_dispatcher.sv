// ============================================================================
// CTA Dispatcher (Single-Kernel)
//  - Dispatcher owns residency credits (slots + SMEM) per SM
//  - One kernel active at a time
//  - 1->N CTA grant bus with full context (includes pre-decoded ctaid{x,y,z})
//  - N->1 completion arbiter to return credits
//  - Round-robin among eligible SMs
// ============================================================================

package cta_dispatch_pkg;
  // Parameterizable widths are expected to be consistent across design.
  // You can import this package wherever you instantiate the dispatcher.
endpackage : cta_dispatch_pkg

//------------------------------------------------------------------------------
// Type definitions (place in a shared package if preferred)
//------------------------------------------------------------------------------
typedef struct packed {
  logic [63:0] start_pc;    // kernel entry PC
  logic [63:0] arg_ptr;     // pointer to kernel argument block
} kernel_exec_info_t;

// Full launch descriptor provided by host/driver for ONE kernel
typedef struct packed {
  // IDs and geometry
  logic [ 7:0]                 kernel_id;       // KID_W defaulted to 8 below
  logic [15:0]                 grid_x;          // CTA_ID_WIDTH default 16
  logic [15:0]                 grid_y;
  logic [15:0]                 grid_z;
  logic [10:0]                 block_x;         // TID_WIDTH default 11
  logic [10:0]                 block_y;
  logic [10:0]                 block_z;

  // Resources
  logic [17:0]                 smem_per_cta;    // SMEM_W default 18 (bytes)
  logic [ 3:0]                 max_cta_per_sm;  // SLOTS_W default 4
  logic [17:0]                 smem_per_sm;     // total SMEM per SM (bytes)

  // Execution
  kernel_exec_info_t           exec;
} launch_desc_t;

// CTA context sent with each grant
typedef struct packed {
  // Identity
  logic [ 7:0]                 kernel_id;
  logic [19:0]                 cta_idx;         // CTA_IDX_W default 20

  // Geometry (dims and decoded 3D CTA IDs)
  logic [15:0]                 grid_x, grid_y, grid_z;
  logic [10:0]                 block_x, block_y, block_z;
  logic [15:0]                 ctaid_x, ctaid_y, ctaid_z;

  // Resources / execution
  logic [17:0]                 smem_size;
  logic [63:0]                 start_pc;
  logic [63:0]                 arg_ptr;
} cta_context_t;

//------------------------------------------------------------------------------
// Dispatcher
//------------------------------------------------------------------------------
module cta_dispatcher #(
  // Fabric parameters
  parameter int unsigned N_SM          = 8,

  // Widths (match typedef defaults above if you change them)
  parameter int unsigned KID_W         = 8,
  parameter int unsigned CTA_IDX_W     = 20,
  parameter int unsigned CTA_ID_WIDTH  = 16,
  parameter int unsigned TID_WIDTH     = 11,
  parameter int unsigned SMEM_W        = 18,
  parameter int unsigned SLOTS_W       = 4
)(
  input  logic                         clk,
  input  logic                         rst_n,

  // ---------------- Host Launch (single kernel) ----------------
  input  logic                         launch_valid,
  output logic                         launch_ready,
  input  launch_desc_t                 launch_desc,

  // ---------------- Dispatcher -> SM Grants (1 -> N) ----------
  output logic        [N_SM-1:0]       sm_grant_valid,
  input  logic        [N_SM-1:0]       sm_grant_ready,
  output cta_context_t [N_SM-1:0]      sm_grant_ctx,

  // ---------------- SM -> Dispatcher Done (N -> 1) -------------
  input  logic        [N_SM-1:0]       sm_done_valid,
  output logic        [N_SM-1:0]       sm_done_ready,
  input  logic [N_SM-1:0][KID_W-1:0]   sm_done_kernel_id,
  input  logic [N_SM-1:0][CTA_IDX_W-1:0] sm_done_cta_idx,
  input  logic [N_SM-1:0][SMEM_W-1:0]  sm_done_smem_release

  // (Optional) add status outputs like kernel_done if you want a pulse
);

  // ---------------- Internal kernel state ----------------
  logic                 kernel_active;
  launch_desc_t         kdesc_q;
  logic [CTA_IDX_W-1:0] next_cta_q;
  logic [CTA_IDX_W-1:0] ctas_rem_q;

  // Per-SM residency mirrors (source of truth for eligibility)
  logic [N_SM-1:0][SLOTS_W-1:0] sm_active_cta_q;
  logic [N_SM-1:0][SMEM_W-1:0]  sm_smem_used_q;

  // ---------------- Helpers ----------------
  // Total CTA count = grid_x * grid_y * grid_z
  function automatic [CTA_IDX_W-1:0] calc_cta_count(input launch_desc_t d);
    calc_cta_count = d.grid_x * d.grid_y * d.grid_z;
  endfunction

  // Linear -> 3D decode:
  //   x = idx % grid_x
  //   y = (idx / grid_x) % grid_y
  //   z = idx / (grid_x * grid_y)
  function automatic void decode_cta_id(
    input  logic [CTA_IDX_W-1:0]   idx,
    input  logic [CTA_ID_WIDTH-1:0] gx,
    input  logic [CTA_ID_WIDTH-1:0] gy,
    output logic [CTA_ID_WIDTH-1:0] id_x,
    output logic [CTA_ID_WIDTH-1:0] id_y,
    output logic [CTA_ID_WIDTH-1:0] id_z
  );
    logic [CTA_IDX_W-1:0] q, r;
    r   = idx % gx;
    q   = idx / gx;
    id_x = r[CTA_ID_WIDTH-1:0];

    r   = q % gy;
    id_y = r[CTA_ID_WIDTH-1:0];

    q   = q / gy;
    id_z = q[CTA_ID_WIDTH-1:0];
  endfunction

  // ---------------- Launch handshake ----------------
  assign launch_ready = !kernel_active;

  // ---------------- Round-robin pointers ----------------
  logic [$clog2(N_SM)-1:0] rr_ptr_q, rr_ptr_d;          // for dispatch
  logic [$clog2(N_SM)-1:0] done_rr_ptr_q, done_rr_ptr_d;// for completion

  // ---------------- Eligibility check (internal credits only) ------
  function automatic logic sm_eligible(
    input int unsigned                 smi,
    input launch_desc_t                kd,
    input logic [SLOTS_W-1:0]          active_slots,
    input logic [SMEM_W-1:0]           smem_used
  );
    logic slots_ok = (active_slots < kd.max_cta_per_sm);
    logic smem_ok  = (smem_used + kd.smem_per_cta <= kd.smem_per_sm);
    sm_eligible = slots_ok && smem_ok;
  endfunction

  // ---------------- Pick SM for dispatch ----------------
  logic                                have_sm;
  logic [$clog2(N_SM)-1:0]             sel_sm;

  always_comb begin
    have_sm = 1'b0;
    sel_sm  = '0;
    for (int unsigned off = 0; off < N_SM; off++) begin
      int unsigned s = (rr_ptr_q + off) % N_SM;
      if (sm_eligible(s, kdesc_q, sm_active_cta_q[s], sm_smem_used_q[s])) begin
        have_sm = 1'b1;
        sel_sm  = s[$bits(sel_sm)-1:0];
        break;
      end
    end
  end

  // ---------------- Dispatch fire condition ----------------
  logic dispatch_fire;
  assign dispatch_fire = kernel_active && (ctas_rem_q != '0) &&
                         have_sm && sm_grant_ready[sel_sm];

  // Pre-decode CTA 3D ID for the NEXT CTA
  logic [CTA_ID_WIDTH-1:0] ctaid_x_dec, ctaid_y_dec, ctaid_z_dec;
  always_comb begin
    decode_cta_id(next_cta_q, kdesc_q.grid_x, kdesc_q.grid_y,
                  ctaid_x_dec, ctaid_y_dec, ctaid_z_dec);
  end

  // Drive 1->N grant bus (one-hot valid + full context)
  always_comb begin
    for (int i = 0; i < N_SM; i++) begin
      sm_grant_valid[i]           = (dispatch_fire && (sel_sm == i));

      sm_grant_ctx[i].kernel_id   = kdesc_q.kernel_id;
      sm_grant_ctx[i].cta_idx     = next_cta_q;

      sm_grant_ctx[i].grid_x      = kdesc_q.grid_x;
      sm_grant_ctx[i].grid_y      = kdesc_q.grid_y;
      sm_grant_ctx[i].grid_z      = kdesc_q.grid_z;
      sm_grant_ctx[i].block_x     = kdesc_q.block_x;
      sm_grant_ctx[i].block_y     = kdesc_q.block_y;
      sm_grant_ctx[i].block_z     = kdesc_q.block_z;

      sm_grant_ctx[i].ctaid_x     = ctaid_x_dec;
      sm_grant_ctx[i].ctaid_y     = ctaid_y_dec;
      sm_grant_ctx[i].ctaid_z     = ctaid_z_dec;

      sm_grant_ctx[i].smem_size   = kdesc_q.smem_per_cta;
      sm_grant_ctx[i].start_pc    = kdesc_q.exec.start_pc;
      sm_grant_ctx[i].arg_ptr     = kdesc_q.exec.arg_ptr;
    end
  end

  // ---------------- N->1 completion RR arbiter ----------------
  logic                                have_done;
  logic [$clog2(N_SM)-1:0]             done_sel_sm;

  always_comb begin
    have_done   = 1'b0;
    done_sel_sm = '0;
    for (int unsigned off = 0; off < N_SM; off++) begin
      int unsigned s = (done_rr_ptr_q + off) % N_SM;
      if (sm_done_valid[s]) begin
        have_done   = 1'b1;
        done_sel_sm = s[$bits(done_sel_sm)-1:0];
        break;
      end
    end
  end

  // Ready is one-hot to the selected SM
  always_comb begin
    for (int i = 0; i < N_SM; i++) begin
      sm_done_ready[i] = have_done && (done_sel_sm == i);
    end
  end

  // ---------------- State updates ----------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      kernel_active   <= 1'b0;
      kdesc_q         <= '0;
      next_cta_q      <= '0;
      ctas_rem_q      <= '0;
      rr_ptr_q        <= '0;
      done_rr_ptr_q   <= '0;
      for (int s = 0; s < N_SM; s++) begin
        sm_active_cta_q[s] <= '0;
        sm_smem_used_q[s]  <= '0;
      end
    end else begin
      // Accept a new kernel launch when idle
      if (launch_valid && launch_ready) begin
        kernel_active <= 1'b1;
        kdesc_q       <= launch_desc;
        next_cta_q    <= '0;
        ctas_rem_q    <= calc_cta_count(launch_desc);
        rr_ptr_q      <= '0;
        done_rr_ptr_q <= '0;
        for (int s = 0; s < N_SM; s++) begin
          sm_active_cta_q[s] <= '0;
          sm_smem_used_q[s]  <= '0;
        end
      end

      // Dispatch: consume credits and advance pointers
      if (dispatch_fire) begin
        sm_active_cta_q[sel_sm] <= sm_active_cta_q[sel_sm] + 1'b1;
        sm_smem_used_q [sel_sm] <= sm_smem_used_q [sel_sm] + kdesc_q.smem_per_cta;
        next_cta_q              <= next_cta_q + 1'b1;
        ctas_rem_q              <= ctas_rem_q - 1'b1;
        rr_ptr_q                <= sel_sm + 1'b1;
      end

      // Completion: return credits (one per cycle via RR arbiter)
      if (have_done) begin
        sm_active_cta_q[done_sel_sm] <= sm_active_cta_q[done_sel_sm] - 1'b1;
        sm_smem_used_q [done_sel_sm] <= sm_smem_used_q [done_sel_sm] -
                                        sm_done_smem_release[done_sel_sm];
        done_rr_ptr_q                <= done_sel_sm + 1'b1;
      end

      // Retire kernel when all CTAs have been granted AND completed
      if (kernel_active) begin
        logic any_active;
        any_active = 1'b0;
        for (int s = 0; s < N_SM; s++) begin
          any_active |= (sm_active_cta_q[s] != '0);
        end
        if ((ctas_rem_q == '0) && !any_active) begin
          kernel_active <= 1'b0;
        end
      end
    end
  end

endmodule
