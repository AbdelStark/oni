-record(block_header, {
    version :: integer(),
    prev_block :: oni_bitcoin:block_hash(),
    merkle_root :: oni_bitcoin:hash256(),
    timestamp :: integer(),
    bits :: integer(),
    nonce :: integer()
}).
