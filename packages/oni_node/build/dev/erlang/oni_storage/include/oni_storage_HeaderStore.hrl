-record(header_store, {
    headers :: gleam@dict:dict(binary(), oni_bitcoin:block_header())
}).
