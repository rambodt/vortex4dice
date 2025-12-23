// =============================================================================
// TEST
// =============================================================================
class tcu_base_test extends uvm_test;
  `uvm_component_utils(tcu_base_test)

  tcu_env env;
  int log_file;

  function new(string name = "tcu_base_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = tcu_env::type_id::create("env", this);
  endfunction
  
  // Configure logging
  function void start_of_simulation_phase(uvm_phase phase);
    super.start_of_simulation_phase(phase);
    
    log_file = $fopen("uvm_test.log", "w");
    if (log_file) begin
      set_report_default_file_hier(log_file);
      set_report_severity_action_hier(UVM_INFO,    UVM_DISPLAY | UVM_LOG);
      set_report_severity_action_hier(UVM_WARNING, UVM_DISPLAY | UVM_LOG);
      set_report_severity_action_hier(UVM_ERROR,   UVM_DISPLAY | UVM_LOG | UVM_COUNT);
      set_report_severity_action_hier(UVM_FATAL,   UVM_DISPLAY | UVM_LOG | UVM_EXIT);
      `uvm_info("TEST", "Logging to: uvm_test.log", UVM_LOW)
    end
    
    `uvm_info("TEST", "========================================", UVM_LOW)
    `uvm_info("TEST", "   TCU UVM TESTBENCH STARTING", UVM_LOW)
    `uvm_info("TEST", "========================================", UVM_LOW)
  endfunction
  
  function void final_phase(uvm_phase phase);
    super.final_phase(phase);
    if (log_file) $fclose(log_file);
  endfunction

  task run_phase(uvm_phase phase);
    tcu_random_seq      rand_seq;
    tcu_coalesce_seq    coal_seq;
    tcu_no_coalesce_seq no_coal_seq;
    
    phase.raise_objection(this, "Starting test");
    
    `uvm_info("TEST", "========== TEST STARTING ==========", UVM_LOW)
    
    // Run coalescing sequence
    coal_seq = tcu_coalesce_seq::type_id::create("coal_seq");
    coal_seq.start(env.agt.sqr);
    #200ns;
    
    // Run non-coalescing sequence
    no_coal_seq = tcu_no_coalesce_seq::type_id::create("no_coal_seq");
    no_coal_seq.start(env.agt.sqr);
    #200ns;
    
    // Run random traffic
    rand_seq = tcu_random_seq::type_id::create("rand_seq");
    rand_seq.num_items = 50;
    rand_seq.start(env.agt.sqr);
    
    #500ns;
    
    `uvm_info("TEST", "========== TEST COMPLETE ==========", UVM_LOW)
    
    phase.drop_objection(this, "Test complete");
  endtask
  
  function void report_phase(uvm_phase phase);
    uvm_report_server server;
    int errors, warnings, fatals;
    
    super.report_phase(phase);
    
    server = uvm_report_server::get_server();
    errors   = server.get_severity_count(UVM_ERROR);
    warnings = server.get_severity_count(UVM_WARNING);
    fatals   = server.get_severity_count(UVM_FATAL);
    
    `uvm_info("TEST", "", UVM_LOW)
    `uvm_info("TEST", "╔══════════════════════════════════════════════════════╗", UVM_LOW)
    `uvm_info("TEST", "║            FINAL TEST SUMMARY                        ║", UVM_LOW)
    `uvm_info("TEST", "╠══════════════════════════════════════════════════════╣", UVM_LOW)
    `uvm_info("TEST", $sformatf("║  Errors:   %4d                                      ║", errors), UVM_LOW)
    `uvm_info("TEST", $sformatf("║  Warnings: %4d                                      ║", warnings), UVM_LOW)
    `uvm_info("TEST", $sformatf("║  Fatals:   %4d                                      ║", fatals), UVM_LOW)
    `uvm_info("TEST", "╠══════════════════════════════════════════════════════╣", UVM_LOW)
    
    if (errors == 0 && fatals == 0)
      `uvm_info("TEST", "║  *** TEST PASSED ***                                 ║", UVM_LOW)
    else
      `uvm_info("TEST", "║  *** TEST FAILED ***                                 ║", UVM_LOW)
    
    `uvm_info("TEST", "╚══════════════════════════════════════════════════════╝", UVM_LOW)
    `uvm_info("TEST", "", UVM_LOW)
    `uvm_info("TEST", "Log file: uvm_test.log", UVM_LOW)
  endfunction

endclass