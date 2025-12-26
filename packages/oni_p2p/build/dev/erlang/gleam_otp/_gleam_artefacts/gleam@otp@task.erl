-module(gleam@otp@task).
-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch]).
-define(FILEPATH, "src/gleam/otp/task.gleam").
-export([async/1, try_await/2, await/2, try_await_forever/1, await_forever/1]).
-export_type([task/1, await_error/0, message/1]).

-if(?OTP_RELEASE >= 27).
-define(MODULEDOC(Str), -moduledoc(Str)).
-define(DOC(Str), -doc(Str)).
-else.
-define(MODULEDOC(Str), -compile([])).
-define(DOC(Str), -compile([])).
-endif.

?MODULEDOC(
    " A task is a kind of process that performs a single task and then shuts\n"
    " down. Commonly tasks are used to convert sequential code into concurrent\n"
    " code by performing computation in another process.\n"
    "\n"
    "    let task = task.async(fn() { do_some_work() })\n"
    "    let value = do_some_other_work()\n"
    "    value + task.await(task, 100)\n"
    "\n"
    " Tasks spawned with async can be awaited on by their caller process (and\n"
    " only their caller) as shown in the example above. They are implemented by\n"
    " spawning a process that sends a message to the caller once the given\n"
    " computation is performed.\n"
    "\n"
    " There are two important things to consider when using `async`:\n"
    "\n"
    " 1. If you are using async tasks, you must await a reply as they are always\n"
    "    sent.\n"
    "\n"
    " 2. async tasks link the caller and the spawned process. This means that,\n"
    "    if the caller crashes, the task will crash too and vice-versa. This is\n"
    "    on purpose: if the process meant to receive the result no longer\n"
    "    exists, there is no purpose in completing the computation.\n"
    "\n"
    " This module is inspired by Elixir's [Task module][1].\n"
    "\n"
    " [1]: https://hexdocs.pm/elixir/master/Task.html\n"
    "\n"
).

-opaque task(GTT) :: {task,
        gleam@erlang@process:pid_(),
        gleam@erlang@process:pid_(),
        gleam@erlang@process:process_monitor(),
        gleam@erlang@process:selector(message(GTT))}.

-type await_error() :: timeout | {exit, gleam@dynamic:dynamic_()}.

-type message(GTU) :: {from_monitor, gleam@erlang@process:process_down()} |
    {from_subject, GTU}.

-file("src/gleam/otp/task.gleam", 49).
?DOC(
    " Spawn a task process that calls a given function in order to perform some\n"
    " work. The result of this function is send back to the parent and can be\n"
    " received using the `await` function.\n"
    "\n"
    " See the top level module documentation for more information on async/await.\n"
).
-spec async(fun(() -> GTV)) -> task(GTV).
async(Work) ->
    Owner = erlang:self(),
    Subject = gleam@erlang@process:new_subject(),
    Pid = gleam@erlang@process:start(
        fun() -> gleam@erlang@process:send(Subject, Work()) end,
        true
    ),
    Monitor = gleam@erlang@process:monitor_process(Pid),
    Selector = begin
        _pipe = gleam_erlang_ffi:new_selector(),
        _pipe@1 = gleam@erlang@process:selecting_process_down(
            _pipe,
            Monitor,
            fun(Field@0) -> {from_monitor, Field@0} end
        ),
        gleam@erlang@process:selecting(
            _pipe@1,
            Subject,
            fun(Field@0) -> {from_subject, Field@0} end
        )
    end,
    {task, Owner, Pid, Monitor, Selector}.

-file("src/gleam/otp/task.gleam", 69).
-spec assert_owner(task(any())) -> nil.
assert_owner(Task) ->
    Self = erlang:self(),
    case erlang:element(2, Task) =:= Self of
        true ->
            nil;

        false ->
            gleam@erlang@process:send_abnormal_exit(
                Self,
                <<"awaited on a task that does not belong to this process"/utf8>>
            )
    end.

-file("src/gleam/otp/task.gleam", 92).
?DOC(
    " Wait for the value computed by a task.\n"
    "\n"
    " If the a value is not received before the timeout has elapsed or if the\n"
    " task process crashes then an error is returned.\n"
).
-spec try_await(task(GTZ), integer()) -> {ok, GTZ} | {error, await_error()}.
try_await(Task, Timeout) ->
    assert_owner(Task),
    case gleam_erlang_ffi:select(erlang:element(5, Task), Timeout) of
        {ok, {from_subject, X}} ->
            gleam_erlang_ffi:demonitor(erlang:element(4, Task)),
            {ok, X};

        {ok, {from_monitor, {process_down, _, Reason}}} ->
            {error, {exit, Reason}};

        {error, nil} ->
            {error, timeout}
    end.

-file("src/gleam/otp/task.gleam", 116).
?DOC(
    " Wait for the value computed by a task.\n"
    "\n"
    " If the a value is not received before the timeout has elapsed or if the\n"
    " task process crashes then this function crashes.\n"
).
-spec await(task(GUD), integer()) -> GUD.
await(Task, Timeout) ->
    Value@1 = case try_await(Task, Timeout) of
        {ok, Value} -> Value;
        _assert_fail ->
            erlang:error(#{gleam_error => let_assert,
                        message => <<"Pattern match failed, no pattern matched the value."/utf8>>,
                        file => <<?FILEPATH/utf8>>,
                        module => <<"gleam/otp/task"/utf8>>,
                        function => <<"await"/utf8>>,
                        line => 117,
                        value => _assert_fail,
                        start => 3757,
                        'end' => 3804,
                        pattern_start => 3768,
                        pattern_end => 3777})
    end,
    Value@1.

-file("src/gleam/otp/task.gleam", 127).
?DOC(
    " Wait endlessly for the value computed by a task.\n"
    "\n"
    " Be Careful! This function does not return until there is a value to\n"
    " receive. If a value is not received then the process will be stuck waiting\n"
    " forever.\n"
).
-spec try_await_forever(task(GUF)) -> {ok, GUF} | {error, await_error()}.
try_await_forever(Task) ->
    assert_owner(Task),
    case gleam_erlang_ffi:select(erlang:element(5, Task)) of
        {from_subject, X} ->
            gleam_erlang_ffi:demonitor(erlang:element(4, Task)),
            {ok, X};

        {from_monitor, {process_down, _, Reason}} ->
            {error, {exit, Reason}}
    end.

-file("src/gleam/otp/task.gleam", 148).
?DOC(
    " Wait endlessly for the value computed by a task.\n"
    "\n"
    " Be Careful! Like `try_await_forever`, this function does not return until there is a value to\n"
    " receive.\n"
    "\n"
    " If the task process crashes then this function crashes.\n"
).
-spec await_forever(task(GUJ)) -> GUJ.
await_forever(Task) ->
    Value@1 = case try_await_forever(Task) of
        {ok, Value} -> Value;
        _assert_fail ->
            erlang:error(#{gleam_error => let_assert,
                        message => <<"Pattern match failed, no pattern matched the value."/utf8>>,
                        file => <<?FILEPATH/utf8>>,
                        module => <<"gleam/otp/task"/utf8>>,
                        function => <<"await_forever"/utf8>>,
                        line => 149,
                        value => _assert_fail,
                        start => 4751,
                        'end' => 4797,
                        pattern_start => 4762,
                        pattern_end => 4771})
    end,
    Value@1.
