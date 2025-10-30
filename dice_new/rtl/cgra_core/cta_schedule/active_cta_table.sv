module active_cta_table #(
    parameter MAX_NUM_CTA = 4,
    parameter CTA_INDEX_WIDTH = $clog2(MAX_NUM_CTA),
    parameter THREAD_WIDTH = 256  // Base thread width per CTA table entry
)(
    input logic clk,
    input logic rst_n,
    
    // Pop interface
    input logic pop_valid,
    input logic [CTA_INDEX_WIDTH-1:0] pop_hw_cta_id,
    
    // Add new entry interface (table is slave)
    input logic add_valid,
    input logic [15:0] add_cta_id_x,
    input logic [15:0] add_cta_id_y,
    input logic [15:0] add_cta_id_z,
    input logic [15:0] add_grid_size_x,
    input logic [15:0] add_grid_size_y,
    input logic [15:0] add_grid_size_z,
    input logic [10:0] add_cta_size_x,  // 11 bits (max 1024)
    input logic [10:0] add_cta_size_y,  // 11 bits (max 1024)
    input logic [10:0] add_cta_size_z,  // 11 bits (max 1024)
    input logic [10:0] add_cta_size,    // Total CTA size (cta_size_x * cta_size_y * cta_size_z)
    input logic [15:0] add_kernel_id,
    output logic add_ready,
    
    // Output popped CTA interface (table is master)
    output logic out_valid,
    output logic [15:0] out_cta_id_x,     // CTA ID coordinates
    output logic [15:0] out_cta_id_y,
    output logic [15:0] out_cta_id_z,
    output logic [10:0] out_cta_size,     // Added: CTA size in pop interface
    output logic [15:0] out_kernel_id,
    input logic out_ready,
    
    // Status outputs
    output logic [MAX_NUM_CTA-1:0] cta_valid,
    output logic [MAX_NUM_CTA-1:0][15:0] cta_id_x,      // Status: CTA ID coordinates for each slot
    output logic [MAX_NUM_CTA-1:0][15:0] cta_id_y,
    output logic [MAX_NUM_CTA-1:0][15:0] cta_id_z,
    output logic [MAX_NUM_CTA-1:0][15:0] grid_size_x,   // Status: Grid size for each slot
    output logic [MAX_NUM_CTA-1:0][15:0] grid_size_y,
    output logic [MAX_NUM_CTA-1:0][15:0] grid_size_z,
    output logic [MAX_NUM_CTA-1:0][10:0] cta_size_x,    // Status: CTA size dimensions for each slot
    output logic [MAX_NUM_CTA-1:0][10:0] cta_size_y,
    output logic [MAX_NUM_CTA-1:0][10:0] cta_size_z,
    output logic [MAX_NUM_CTA-1:0][10:0] cta_size,      // Status: Total CTA size for each slot
    output logic [MAX_NUM_CTA-1:0][15:0] kernel_id,     // Status: Kernel ID for each slot
    output logic full,
    output logic [CTA_INDEX_WIDTH-1:0] next_empty_cta_index
);

    // Calculate number of entries needed for a CTA
    // Optimized for power-of-2 THREAD_WIDTH using bit shifts
    function automatic logic [CTA_INDEX_WIDTH:0] calc_entries_needed(input logic [10:0] cta_size);
        // For power-of-2 THREAD_WIDTH, we can use bit shifts
        // entries_needed = ceil(cta_size / THREAD_WIDTH) = (cta_size + THREAD_WIDTH - 1) >> log2(THREAD_WIDTH)
        logic [10:0] adjusted_size;
        adjusted_size = cta_size + THREAD_WIDTH - 1;
        return adjusted_size >> $clog2(THREAD_WIDTH);
    endfunction

    // CTA table entry structure
    typedef struct packed {
        logic valid;
        logic is_primary;      // True for the first entry of a multi-entry CTA
        logic [CTA_INDEX_WIDTH:0] entries_used; // Number of entries used by this CTA
        logic [15:0] cta_id_x;
        logic [15:0] cta_id_y;
        logic [15:0] cta_id_z;
        logic [15:0] grid_size_x;
        logic [15:0] grid_size_y;
        logic [15:0] grid_size_z;
        logic [10:0] cta_size_x;
        logic [10:0] cta_size_y;
        logic [10:0] cta_size_z;
        logic [10:0] cta_size;
        logic [15:0] kernel_id;
    } cta_entry_t;
    
    // CTA table storage
    cta_entry_t cta_table [MAX_NUM_CTA-1:0];
    
    // Output buffer for popped entries
    logic output_buffer_valid;
    logic [15:0] output_buffer_cta_id_x;
    logic [15:0] output_buffer_cta_id_y;
    logic [15:0] output_buffer_cta_id_z;
    logic [10:0] output_buffer_cta_size;
    logic [15:0] output_buffer_kernel_id;
    
    // Internal signals - simplified
    logic [CTA_INDEX_WIDTH-1:0] empty_index;
    logic found_empty;
    logic [CTA_INDEX_WIDTH:0] entries_needed;
    
    // Calculate entries needed for incoming CTA
    assign entries_needed = calc_entries_needed(add_cta_size);
    
    // Find next empty entry - simplified since we assume requests won't exceed available space
    always_comb begin
        found_empty = 1'b0;
        empty_index = '0;
        
        // Simple search for first empty slot - no need to check consecutive availability
        for (int i = 0; i < MAX_NUM_CTA; i++) begin
            if (!cta_table[i].valid && !found_empty) begin
                empty_index = i[CTA_INDEX_WIDTH-1:0];
                found_empty = 1'b1;
            end
        end
    end
    
    // Output assignments - simplified
    assign full = !found_empty;
    assign next_empty_cta_index = empty_index;
    assign add_ready = found_empty; // Simplified: assume request will always fit if space exists
    
    // Output interface
    assign out_valid = output_buffer_valid;
    assign out_cta_id_x = output_buffer_cta_id_x;
    assign out_cta_id_y = output_buffer_cta_id_y;
    assign out_cta_id_z = output_buffer_cta_id_z;
    assign out_cta_size = output_buffer_cta_size;
    assign out_kernel_id = output_buffer_kernel_id;

    logic pop_this_cycle;
    logic output_consumed_this_cycle;

    // CTA valid outputs and status information - only from primary entries
    always_comb begin
        for (int i = 0; i < MAX_NUM_CTA; i++) begin
            // Only show as valid and output data if this is a primary entry
            cta_valid[i] = cta_table[i].valid && cta_table[i].is_primary;
            
            if (cta_table[i].valid && cta_table[i].is_primary) begin
                // Output real data for primary entries
                cta_id_x[i] = cta_table[i].cta_id_x;
                cta_id_y[i] = cta_table[i].cta_id_y;
                cta_id_z[i] = cta_table[i].cta_id_z;
                grid_size_x[i] = cta_table[i].grid_size_x;
                grid_size_y[i] = cta_table[i].grid_size_y;
                grid_size_z[i] = cta_table[i].grid_size_z;
                cta_size_x[i] = cta_table[i].cta_size_x;
                cta_size_y[i] = cta_table[i].cta_size_y;
                cta_size_z[i] = cta_table[i].cta_size_z;
                cta_size[i] = cta_table[i].cta_size;
                kernel_id[i] = cta_table[i].kernel_id;
            end else begin
                // Output zeros for non-primary or invalid entries
                cta_id_x[i] = '0;
                cta_id_y[i] = '0;
                cta_id_z[i] = '0;
                grid_size_x[i] = '0;
                grid_size_y[i] = '0;
                grid_size_z[i] = '0;
                cta_size_x[i] = '0;
                cta_size_y[i] = '0;
                cta_size_z[i] = '0;
                cta_size[i] = '0;
                kernel_id[i] = '0;
            end
        end
    end
    
    // Main table logic
    always_ff @(posedge clk or negedge rst_n) begin
        logic [CTA_INDEX_WIDTH:0] entries_to_clear;
        if (!rst_n) begin
            // Reset all entries
            for (int i = 0; i < MAX_NUM_CTA; i++) begin
                cta_table[i].valid <= 1'b0;
                cta_table[i].is_primary <= 1'b0;
                cta_table[i].entries_used <= '0;
                cta_table[i].cta_id_x <= '0;
                cta_table[i].cta_id_y <= '0;
                cta_table[i].cta_id_z <= '0;
                cta_table[i].grid_size_x <= '0;
                cta_table[i].grid_size_y <= '0;
                cta_table[i].grid_size_z <= '0;
                cta_table[i].cta_size_x <= '0;
                cta_table[i].cta_size_y <= '0;
                cta_table[i].cta_size_z <= '0;
                cta_table[i].cta_size <= '0;
                cta_table[i].kernel_id <= '0;
            end
            
            // Reset output buffer
            output_buffer_valid <= 1'b0;
            output_buffer_cta_id_x <= '0;
            output_buffer_cta_id_y <= '0;
            output_buffer_cta_id_z <= '0;
            output_buffer_cta_size <= '0;
            output_buffer_kernel_id <= '0;
            
        end else begin
            // Handle simultaneous pop and output buffer operations
            
            pop_this_cycle = pop_valid && cta_table[pop_hw_cta_id].valid;
            output_consumed_this_cycle = out_valid && out_ready;
            
            if (pop_this_cycle && output_consumed_this_cycle) begin
                // Pop and output in same cycle - directly replace buffer contents
                output_buffer_valid <= 1'b1;
                output_buffer_cta_id_x <= cta_table[pop_hw_cta_id].cta_id_x;
                output_buffer_cta_id_y <= cta_table[pop_hw_cta_id].cta_id_y;
                output_buffer_cta_id_z <= cta_table[pop_hw_cta_id].cta_id_z;
                output_buffer_cta_size <= cta_table[pop_hw_cta_id].cta_size;
                output_buffer_kernel_id <= cta_table[pop_hw_cta_id].kernel_id;
                
                // Clear all entries used by this CTA
                entries_to_clear = cta_table[pop_hw_cta_id].entries_used;
                
                for (int j = 0; j < MAX_NUM_CTA; j++) begin
                    if (j >= pop_hw_cta_id && j < (pop_hw_cta_id + entries_to_clear)) begin
                        cta_table[j].valid <= 1'b0;
                        cta_table[j].is_primary <= 1'b0;
                        cta_table[j].entries_used <= '0;
                        cta_table[j].cta_id_x <= '0;
                        cta_table[j].cta_id_y <= '0;
                        cta_table[j].cta_id_z <= '0;
                        cta_table[j].grid_size_x <= '0;
                        cta_table[j].grid_size_y <= '0;
                        cta_table[j].grid_size_z <= '0;
                        cta_table[j].cta_size_x <= '0;
                        cta_table[j].cta_size_y <= '0;
                        cta_table[j].cta_size_z <= '0;
                        cta_table[j].cta_size <= '0;
                        cta_table[j].kernel_id <= '0;
                    end
                end
                
            end else if (pop_this_cycle && !output_buffer_valid) begin
                // Pop when buffer is empty - store in buffer
                output_buffer_valid <= 1'b1;
                output_buffer_cta_id_x <= cta_table[pop_hw_cta_id].cta_id_x;
                output_buffer_cta_id_y <= cta_table[pop_hw_cta_id].cta_id_y;
                output_buffer_cta_id_z <= cta_table[pop_hw_cta_id].cta_id_z;
                output_buffer_cta_size <= cta_table[pop_hw_cta_id].cta_size;
                output_buffer_kernel_id <= cta_table[pop_hw_cta_id].kernel_id;
                
                // Clear all entries used by this CTA
                entries_to_clear = cta_table[pop_hw_cta_id].entries_used;
                
                for (int j = 0; j < MAX_NUM_CTA; j++) begin
                    if (j >= pop_hw_cta_id && j < (pop_hw_cta_id + entries_to_clear)) begin
                        cta_table[j].valid <= 1'b0;
                        cta_table[j].is_primary <= 1'b0;
                        cta_table[j].entries_used <= '0;
                        cta_table[j].cta_id_x <= '0;
                        cta_table[j].cta_id_y <= '0;
                        cta_table[j].cta_id_z <= '0;
                        cta_table[j].grid_size_x <= '0;
                        cta_table[j].grid_size_y <= '0;
                        cta_table[j].grid_size_z <= '0;
                        cta_table[j].cta_size_x <= '0;
                        cta_table[j].cta_size_y <= '0;
                        cta_table[j].cta_size_z <= '0;
                        cta_table[j].cta_size <= '0;
                        cta_table[j].kernel_id <= '0;
                    end
                end
                
            end else if (output_consumed_this_cycle) begin
                // Only output buffer consumed - clear buffer
                output_buffer_valid <= 1'b0;
                output_buffer_cta_id_x <= '0;
                output_buffer_cta_id_y <= '0;
                output_buffer_cta_id_z <= '0;
                output_buffer_cta_size <= '0;
                output_buffer_kernel_id <= '0;
            end
            // If pop_this_cycle && output_buffer_valid && !output_consumed_this_cycle
            // then we can't pop because buffer is full - pop is ignored
            
            // Handle add operation
            if (add_valid && add_ready) begin
                // Allocate consecutive entries for this CTA
                for (int j = 0; j < MAX_NUM_CTA; j++) begin
                    if (j >= empty_index && j < (empty_index + entries_needed)) begin
                        cta_table[j].valid <= 1'b1;
                        cta_table[j].is_primary <= (j == empty_index); // Only first entry is primary
                        cta_table[j].entries_used <= entries_needed;
                        
                        if (j == empty_index) begin
                            // Primary entry gets all the data
                            cta_table[j].cta_id_x <= add_cta_id_x;
                            cta_table[j].cta_id_y <= add_cta_id_y;
                            cta_table[j].cta_id_z <= add_cta_id_z;
                            cta_table[j].grid_size_x <= add_grid_size_x;
                            cta_table[j].grid_size_y <= add_grid_size_y;
                            cta_table[j].grid_size_z <= add_grid_size_z;
                            cta_table[j].cta_size_x <= add_cta_size_x;
                            cta_table[j].cta_size_y <= add_cta_size_y;
                            cta_table[j].cta_size_z <= add_cta_size_z;
                            cta_table[j].cta_size <= add_cta_size;
                            cta_table[j].kernel_id <= add_kernel_id;
                        end else begin
                            // Non-primary entries have no meaningful data (but store entries_used for cleanup)
                            cta_table[j].cta_id_x <= '0;
                            cta_table[j].cta_id_y <= '0;
                            cta_table[j].cta_id_z <= '0;
                            cta_table[j].grid_size_x <= '0;
                            cta_table[j].grid_size_y <= '0;
                            cta_table[j].grid_size_z <= '0;
                            cta_table[j].cta_size_x <= '0;
                            cta_table[j].cta_size_y <= '0;
                            cta_table[j].cta_size_z <= '0;
                            cta_table[j].cta_size <= '0;
                            cta_table[j].kernel_id <= '0;
                        end
                    end
                end
            end
        end
    end

    // Debug and validation logic
    `ifndef SYNTHESIS
    // Compile-time check that THREAD_WIDTH is power of 2
    initial begin
        if ((THREAD_WIDTH & (THREAD_WIDTH - 1)) != 0) begin
            $fatal(1, "THREAD_WIDTH (%0d) must be a power of 2", THREAD_WIDTH);
        end
    end
    
    always @(posedge clk) begin
        logic [31:0] calculated_size;
        if (rst_n && add_valid && add_ready) begin
            // Check that the total CTA size doesn't exceed maximum
            if (add_cta_size > (MAX_NUM_CTA * THREAD_WIDTH)) begin
                $error("CTA size %0d exceeds maximum of %0d (MAX_NUM_CTA=%0d * THREAD_WIDTH=%0d)", 
                       add_cta_size, MAX_NUM_CTA * THREAD_WIDTH, MAX_NUM_CTA, THREAD_WIDTH);
            end
            
            // Simplified validation: assume upstream ensures requests fit
            // Check that add_cta_size matches the product of dimensions
            calculated_size = add_cta_size_x * add_cta_size_y * add_cta_size_z;
            if (calculated_size != add_cta_size) begin
                $warning("CTA size mismatch: %0d (input) vs %0d (calculated_size calculated from %0dx%0dx%0d)", 
                        add_cta_size, calculated_size, add_cta_size_x, add_cta_size_y, add_cta_size_z);
            end
            
            // Display allocation information
            $display("CTA Table: Allocated CTA(%0d,%0d,%0d) with %0d threads to entries %0d-%0d (THREAD_WIDTH=%0d)",
                     add_cta_id_x, add_cta_id_y, add_cta_id_z, add_cta_size, 
                     empty_index, empty_index + entries_needed - 1, THREAD_WIDTH);
        end
        
        if (rst_n && pop_valid && cta_table[pop_hw_cta_id].valid) begin
            $display("CTA Table: Popping CTA(%0d,%0d,%0d) from entry %0d, clearing %0d entries",
                     cta_table[pop_hw_cta_id].cta_id_x, cta_table[pop_hw_cta_id].cta_id_y, 
                     cta_table[pop_hw_cta_id].cta_id_z, pop_hw_cta_id, 
                     cta_table[pop_hw_cta_id].entries_used);
        end
    end
    `endif

endmodule