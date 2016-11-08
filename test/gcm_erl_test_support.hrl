-ifndef(__GCM_ERL_TEST_SUPPORT_HRL__).
-define(__GCM_ERL_TEST_SUPPORT_HRL__, true).

-define(ASSERT, true). % Ensure assert macros are in force.
-include_lib("stdlib/include/assert.hrl").

-define(assertMsg(Cond, Fmt, Args),
    case (Cond) of
        true ->
            ok;
        false ->
            ct:fail("Assertion failed: ~p~n" ++ Fmt, [??Cond] ++ Args)
    end
).

-endif.
