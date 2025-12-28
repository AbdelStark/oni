-module(benchmark_ffi).
-export([monotonic_time_us/0, wall_clock_time_seconds/0]).

%% Get monotonic time in microseconds
monotonic_time_us() ->
    erlang:monotonic_time(microsecond).

%% Get wall clock time in seconds (Unix timestamp)
wall_clock_time_seconds() ->
    erlang:system_time(second).
