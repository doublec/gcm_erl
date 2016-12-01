-module(gcm_erl_util).

-export([
         sanitize_opts/1
        ]).

%% @doc Search `Opts`, which may be either a proplist
%% `[{service, Service::proplist()}, {sessions, Sessions::proplist()}]',
%% or a list of sessions, `[[{name, string()}, {config, proplist()}]]',
%% and redact sensitive data, returning the redacted argument.
%% Needless to say, the redacted argument is pretty useless for
%% anything other than logging.
%%
%% Currently this only redacts `api_key'.
-spec sanitize_opts(Opts) -> Result when
      Opts :: list(), Result :: list().
sanitize_opts(Opts) when is_list(Opts) ->
    case proplists:get_value(sessions, Opts) of
        undefined ->
            sanitize_session(Opts);
        Sessions ->
            ks(sessions, sanitize_sessions(Sessions), Opts)
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================
sanitize_sessions(Sessions) when is_list(Sessions) ->
    [sanitize_session(Session) || Session <- Sessions].

sanitize_session(Session) when is_list(Session) ->
    case proplists:get_value(config, Session) of
        undefined -> % See if it's maybe a list of sessions
            maybe_sanitize_list_of_sessions(Session);
        Config ->
            ks(config, sanitize_config(Config), Session)
    end.

sanitize_config(Config) when is_list(Config) ->
    case proplists:get_value(api_key, Config) of
        undefined ->
            Config;
        _ ->
            ks(api_key, <<"<redacted>">>, Config)
    end.

maybe_sanitize_list_of_sessions([[_|_]=MaybeSession|_]=L) ->
    case lists:keymember(config, 1, MaybeSession) of
        true ->
            sanitize_sessions(L);
        false ->
            L
    end;
maybe_sanitize_list_of_sessions(Thing) ->
    Thing.

ks(Key, Val, Props) ->
    lists:keystore(Key, 1, Props, {Key, Val}).

