-record(node_config, {
    network :: oni_bitcoin:network(),
    data_dir :: binary(),
    rpc_port :: integer(),
    p2p_port :: integer(),
    max_connections :: integer()
}).
