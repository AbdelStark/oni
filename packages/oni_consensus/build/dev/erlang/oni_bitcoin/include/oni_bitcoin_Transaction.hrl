-record(transaction, {
    version :: integer(),
    inputs :: list(oni_bitcoin:tx_in()),
    outputs :: list(oni_bitcoin:tx_out()),
    lock_time :: integer()
}).
