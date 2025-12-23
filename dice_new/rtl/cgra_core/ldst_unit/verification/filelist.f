# filelist.f

# ===========================================
# DUT RTL Files
# ===========================================
../memory_cmd_coalesce_buffer.sv
../temporal_coalescing_unit.sv
../../dispatcher/sync_fifo_read_unreg.sv

# ===========================================
# Testbench Files
# ===========================================
# Interface (must come before package that references it)
tcu_if.sv

# UVM Package (includes all .svh files)
tcu_pkg.sv

# Top-level testbench
tcu_tb_top.sv