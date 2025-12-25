-record(script_context, {
    stack :: list(bitstring()),
    alt_stack :: list(bitstring()),
    op_count :: integer(),
    script :: bitstring(),
    script_pos :: integer(),
    codesep_pos :: integer(),
    flags :: oni_consensus:script_flags(),
    exec_stack :: list(boolean())
}).
