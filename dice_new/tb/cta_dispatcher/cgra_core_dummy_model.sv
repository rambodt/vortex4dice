`include "dice_define.vh"
`include "dice_pkg.sv"

module cgra_core_dummy_model #(
  parameter int unsigned CORE_ID = 0,
  parameter int unsigned MAX_CTA = `DICE_NUM_MAX_CTA_PER_CORE,
  parameter int unsigned MIN_LAT = 10,
  parameter int unsigned MAX_LAT = 40
)(
  input  logic                         clk,
  input  logic                         rst_n,

  // --- From CTA dispatcher ---
  input  logic                         sm_grant_valid,
  output logic                         sm_grant_ready,
  input  dice_pkg::dice_cta_desc_t     sm_grant_ctx,

  // --- To CTA dispatcher ---
  output logic                         sm_done_valid,
  input  logic                         sm_done_ready,
  output dice_pkg::dice_cta_id_t       sm_done_cta_id
);

  import dice_pkg::*;

  // ------------------------------------------------------------------
  // Internal storage: MAX_CTA slots with (valid, id, timer)
  // ------------------------------------------------------------------
  logic                 slot_valid [MAX_CTA];
  dice_cta_id_t         slot_id    [MAX_CTA];
  logic [7:0]           slot_timer [MAX_CTA];

  // ------------------------------------------------------------------
  // Free-slot detection
  // ------------------------------------------------------------------
  logic has_free;
  int   free_idx;

  always_comb begin
    int i;  // ✅ declare at top
    has_free = 1'b0;
    free_idx = -1;
    for (i = 0; i < MAX_CTA; i++) begin
      if (!slot_valid[i]) begin
        has_free = 1'b1;
        free_idx = i;
        break;
      end
    end
  end

  assign sm_grant_ready = has_free;

  // ------------------------------------------------------------------
  // Done-slot detection
  // ------------------------------------------------------------------
  logic have_done;
  int   done_idx;

  always_comb begin
    int j;  // ✅ declare at top
    have_done = 1'b0;
    done_idx  = -1;
    for (j = 0; j < MAX_CTA; j++) begin
      if (slot_valid[j] && (slot_timer[j] == 8'd0)) begin
        have_done = 1'b1;
        done_idx  = j;
        break;
      end
    end
    sm_done_valid  = have_done;
    sm_done_cta_id = (have_done && done_idx >= 0) ? slot_id[done_idx] : '0;
  end

  // ------------------------------------------------------------------
  // Sequential behavior
  // ------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    int k, m;  // ✅ declare at top of sequential block
    if (!rst_n) begin
      for (k = 0; k < MAX_CTA; k++) begin
        slot_valid[k] <= 1'b0;
        slot_id[k]    <= '0;
        slot_timer[k] <= '0;
      end
    end else begin
      // Accept new CTA if free slot exists
      if (sm_grant_valid && sm_grant_ready && (free_idx >= 0)) begin
        slot_valid[free_idx] <= 1'b1;
        slot_id[free_idx]    <= sm_grant_ctx.cta_id;
        slot_timer[free_idx] <= (MAX_LAT > MIN_LAT)
                                ? (MIN_LAT + {$urandom_range(MAX_LAT - MIN_LAT)})
                                : MIN_LAT[7:0];
      end

      // Decrement timers for active CTAs
      for (m = 0; m < MAX_CTA; m++) begin
        if (slot_valid[m] && (slot_timer[m] != 8'd0))
          slot_timer[m] <= slot_timer[m] - 8'd1;
      end

      // Free finished slot after handshake
      if (sm_done_valid && sm_done_ready && (done_idx >= 0))
        slot_valid[done_idx] <= 1'b0;
    end
  end

`ifndef SYNTHESIS
  // ------------------------------------------------------------------
  // Debug prints
  // ------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (sm_grant_valid && sm_grant_ready)
      $display("[%0t][CGRA%0d] Dispatch CTA (x=%0d,y=%0d,z=%0d)",
               $time, CORE_ID,
               sm_grant_ctx.cta_id.x, sm_grant_ctx.cta_id.y, sm_grant_ctx.cta_id.z);
    if (sm_done_valid && sm_done_ready)
      $display("[%0t][CGRA%0d] Done CTA (x=%0d,y=%0d,z=%0d)",
               $time, CORE_ID,
               sm_done_cta_id.x, sm_done_cta_id.y, sm_done_cta_id.z);
  end
`endif

endmodule
