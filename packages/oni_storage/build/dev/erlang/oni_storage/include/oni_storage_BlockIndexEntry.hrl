-record(block_index_entry, {
    hash :: oni_bitcoin:block_hash(),
    prev_hash :: oni_bitcoin:block_hash(),
    height :: integer(),
    status :: oni_storage:block_status(),
    num_tx :: integer(),
    file_pos :: gleam@option:option(integer()),
    undo_pos :: gleam@option:option(integer())
}).
