{application, oni_consensus, [
    {vsn, "0.1.0"},
    {applications, [gleam_erlang,
                    gleam_stdlib,
                    gleeunit,
                    oni_bitcoin]},
    {description, "Consensus rules, script evaluation, and validation engine for oni."},
    {modules, [oni_consensus_test]},
    {registered, []}
]}.
