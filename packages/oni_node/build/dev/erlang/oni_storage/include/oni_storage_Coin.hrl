-record(coin, {
    output :: oni_bitcoin:tx_out(),
    height :: integer(),
    is_coinbase :: boolean()
}).
