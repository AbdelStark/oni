-record(chainstate, {
    best_block :: oni_bitcoin:block_hash(),
    best_height :: integer(),
    total_tx :: integer(),
    pruned :: boolean(),
    pruned_height :: gleam@option:option(integer())
}).
