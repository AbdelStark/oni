-record(tx_in, {
    prevout :: oni_bitcoin:out_point(),
    script_sig :: oni_bitcoin:script(),
    sequence :: integer(),
    witness :: list(bitstring())
}).
