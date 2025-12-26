{application, oni_node, [
    {vsn, "0.1.0"},
    {applications, [gleam_erlang,
                    gleam_otp,
                    gleam_stdlib,
                    gleeunit,
                    oni_bitcoin,
                    oni_consensus,
                    oni_p2p,
                    oni_rpc,
                    oni_storage]},
    {description, "The oni node OTP application (wiring + supervision)."},
    {modules, []},
    {registered, []}
]}.
