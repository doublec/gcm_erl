-ifndef(__GCM_ERL_INTERNAL_HRL).
-define(__GCM_ERL_INTERNAL_HRL, true).

-define(assert(Cond),
    case (Cond) of
        true ->
            true;
        false ->
            throw({assertion_failed, ??Cond})
    end).

-define(assertList(Term),
        begin ?assert(is_list(Term)), Term end).
-define(assertInt(Term),
        begin ?assert(is_integer(Term)), Term end).
-define(assertPosInt(Term),
        begin ?assert(is_integer(Term) andalso Term > 0), Term end).
-define(assertNonNegInt(Term),
        begin ?assert(is_integer(Term) andalso Term >= 0), Term end).
-define(assertBinary(Term),
        begin ?assert(is_binary(Term)), Term end).
-define(assertReadFile(Filename),
        ((fun(Fname) ->
                 case file:read_file(Fname) of
                     {ok, B} ->
                         B;
                     {error, Reason} ->
                         throw({file_read_error,
                                {Reason, file:format_error(Reason), Fname}})
                 end
         end)(Filename))).

-define(LOG_GENERAL(Level, Fmt, Args),
        lager:Level("~p: " ++ Fmt, [?MODULE] ++ Args)).

-define(LOG_INFO(Fmt, Args), ?LOG_GENERAL(info, Fmt, Args)).
-define(LOG_DEBUG(Fmt, Args), ?LOG_GENERAL(debug, Fmt, Args)).
-define(LOG_ERROR(Fmt, Args), ?LOG_GENERAL(error, Fmt, Args)).
-define(LOG_WARNING(Fmt, Args), ?LOG_GENERAL(warning, Fmt, Args)).

-ifdef(namespaced_queues).
-type sc_queue() :: queue:queue().
-else.
-type sc_queue() :: queue().
-endif.


-endif.

