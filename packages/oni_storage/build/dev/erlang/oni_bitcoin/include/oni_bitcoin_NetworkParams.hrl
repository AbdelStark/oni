-record(network_params, {
    network :: oni_bitcoin:network(),
    p2pkh_prefix :: integer(),
    p2sh_prefix :: integer(),
    bech32_hrp :: binary(),
    default_port :: integer(),
    genesis_hash :: oni_bitcoin:block_hash()
}).
