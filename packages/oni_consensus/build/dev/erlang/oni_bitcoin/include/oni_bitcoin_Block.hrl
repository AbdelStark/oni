-record(block, {
    header :: oni_bitcoin:block_header(),
    transactions :: list(oni_bitcoin:transaction())
}).
