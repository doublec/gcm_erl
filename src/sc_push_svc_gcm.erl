%%% ==========================================================================
%%% Copyright 2015 Silent Circle
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%% ==========================================================================

%%%-------------------------------------------------------------------
%%% @author Edwin Fine <efine@silentcircle.com>
%%% @copyright 2015 Silent Circle
%%% @doc Google Cloud Messaging Push Notification Service (gcm) API.
%%%
%%% This is the API to the Google Cloud Messaging Service Provider. It
%%% runs as a supervisor, so should be started either from an application
%%% module or a supervisor.
%%%
%%% == Synopsis ==
%%%
%%% === Configuration ===
%%%
%%% Start the API by calling start_link/1 and providing a list of
%%% sessions to start. Each session is a proplist as shown below:
%%% ```
%%% [
%%%     {name, 'gcm-com.example.Example'},
%%%     {config, [
%%%             {api_key, <<"AIzaffffffffffffffffffffffffffffffff73w">>},
%%%             {ssl_opts, [{verify, verify_none}]},
%%%             {uri, "https://gcm-http.googleapis.com/gcm/send"},
%%%             {max_attempts, 5},
%%%             {retry_interval, 1},
%%%             {max_req_ttl, 600}
%%%         ]}
%%% ]
%%% '''
%%% Note that the session <em>must</em> be named `gcm-AppId',
%%% where `AppId` is the Android App ID, such as
%%% `com.example.Example'.
%%%
%%% === Sending an alert via the API ===
%%%
%%% Alerts should usually be sent via the API, `gcm_erl'.
%%%
%%% ```
%%% Alert = <<"Hello, Android!">>,
%%% Notification = [{alert, Alert}],
%%% {ok, SeqNo} = gcm_erl:send(my_push_tester, Notification).
%%% '''
%%%
%%% === Sending an alert via a session (for testing only) ===
%%%
%%% ```
%%% Notification = [
%%%     {id, sc_util:to_bin(RegId)}, % Required key
%%%     {data, [{alert, sc_util:to_bin(Msg)}]}
%%% ],
%%% {ok, SeqNo} = gcm_erl_session:send(my_push_tester, Notification).
%%% '''
%%%
%%% For multiple registration ids:
%%%
%%% ```
%%% Notification = [
%%%     {registration_ids, [sc_util:to_bin(RegId) || RegId <- RegIds]}, % Required key
%%%     {data, [{alert, sc_util:to_bin(Msg)}]}
%%% ],
%%% {ok, SeqNo} = gcm_erl_session:send(my_push_tester, Notification).
%%% '''
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(sc_push_svc_gcm).
-behaviour(supervisor).

%%--------------------------------------------------------------------
%% Includes
%%--------------------------------------------------------------------
-include_lib("lager/include/lager.hrl").

%%--------------------------------------------------------------------
%% Defines
%%--------------------------------------------------------------------
-define(SERVER, ?MODULE).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type, Timeout),
    {I, {I, start_link, []}, permanent, Timeout, Type, [I]}
).

-define(CHILD_ARGS(I, Args, Type, Timeout),
    {I, {I, start_link, Args}, permanent, Timeout, Type, [I]}
).


%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------
-export([
        start_link/1,
        start_session/2,
        stop_session/1,
        send/2,
        send/3,
        async_send/2,
        async_send/3
    ]).

%% Supervisor callbacks
-export([init/1]).

%% ===================================================================
%% API functions
%% ===================================================================
%% @doc `Opts' is a list of proplists.
%% Each proplist is a session definition containing
%% `name' and `config' keys.
-spec start_link(Opts::list()) -> {ok, pid()} | {error, term()}.
start_link(Opts) when is_list(Opts) ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, Opts).

%%--------------------------------------------------------------------
%% @doc Start named session for specific host and certificate as
%% described in the options proplist `Opts'.
%% @see gcm_erl_session:start_session/2. <b>Options</b> in `gcm_erl_session'
%% @end
%%--------------------------------------------------------------------
-spec start_session(Name::atom(), Opts::list()) ->
    {ok, pid()} | {error, already_started} | {error, Reason::term()}.
start_session(Name, Opts) when is_atom(Name), is_list(Opts) ->
    gcm_erl_session_sup:start_child(Name, Opts).

%%--------------------------------------------------------------------
%% @doc Stop named session.
%% @end
%%--------------------------------------------------------------------
-spec stop_session(Name::atom()) -> ok | {error, Reason::term()}.
stop_session(Name) when is_atom(Name) ->
    gcm_erl_session_sup:stop_child(Name).

%%--------------------------------------------------------------------
%% @doc Send a notification specified by proplist `Notification'
%% @end
%%--------------------------------------------------------------------
-spec send(term(), gcm_json:notification()) ->
    {ok, Ref::term()} | {error, Reason::term()}.
send(Name, Notification) when is_list(Notification) ->
    send(sync, Name, Notification, []).

%%--------------------------------------------------------------------
%% @doc Send a notification specified by proplist `Notification' and
%% with options `Opts'.
%% @see gcm_erl_session:send/3.
%% @end
%%--------------------------------------------------------------------
-spec send(term(), gcm_json:notification(), [{atom(), term()}]) ->
    {ok, Ref::term()} | {error, Reason::term()}.
send(Name, Notification, Opts) when is_list(Notification), is_list(Opts) ->
    send(sync, Name, Notification, Opts).

%%--------------------------------------------------------------------
%% @doc Asynchronously sends a notification specified by proplist
%% `Notification'; Same as {@link send/2} beside returning only 'ok' on success.
%% @end
%%--------------------------------------------------------------------
-spec async_send(term(), gcm_json:notification()) ->
    ok | {error, Reason::term()}.
async_send(Name, Notification) when is_list(Notification) ->
    send(async, Name, Notification, []).

%%--------------------------------------------------------------------
%% @doc Asynchronously sends a notification specified by proplist
%% `Notification'; Same as {@link send/3} beside returning only 'ok' on success.
%% @end
%%--------------------------------------------------------------------
-spec async_send(term(), gcm_json:notification(), [{atom(), term()}]) ->
    ok | {error, Reason::term()}.
async_send(Name, Notification, Opts) when is_list(Notification), is_list(Opts) ->
    send(async, Name, Notification, Opts).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init(Opts) ->
    _ = lager:info("Starting service with opts: ~p", [Opts]),
    RestartStrategy    = one_for_one,
    MaxRestarts        = 10, % If there are more than this many restarts
    MaxTimeBetRestarts = 60, % In this many seconds, then terminate supervisor

    Timeout = sc_util:val(start_timeout, Opts, 5000),

    SupFlags = {RestartStrategy, MaxRestarts, MaxTimeBetRestarts},

    Children = [
        ?CHILD_ARGS(gcm_erl_session_sup, [Opts], supervisor, infinity),
        ?CHILD(gcm_req_sched, worker, Timeout)
    ],

    {ok, {SupFlags, Children}}.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

send(Mode, Name, Notification, Opts) when is_list(Notification), is_list(Opts) ->
    To = get_destination(Notification),
    Data = get_data(Notification),
    NewNotification = store_props([To, Data], Notification),
    case Mode of
        sync -> gcm_erl_session:send(Name, NewNotification, Opts);
        async -> gcm_erl_session:async_send(Name, NewNotification, Opts)
    end.

get_data(Notification) ->
    Data = case {sc_util:val(data, Notification),
                 sc_util:val(alert, Notification)} of
        {D, _} when is_list(D) ->
            D;
        {undefined, Alert} when is_list(Alert); is_binary(Alert) ->
            [{<<"alert">>, sc_util:to_bin(Alert)}];
        {_, _} ->
            throw({missing_data_or_alert, Notification})
    end,
    {data, Data}.

get_destination(Notification) ->
    case {sc_util:val(id, Notification), sc_util:val(token, Notification)} of
        {Id, _} when is_list(Id); is_binary(Id) ->
            {id, Id};
        {_, Id} when is_list(Id); is_binary(Id) ->
            {id, Id};
        {undefined, undefined} ->
            RIs = case sc_util:val(registration_ids, Notification) of
                [RegId|_] = L when is_binary(RegId); is_list(RegId) ->
                    L;
                _ ->
                    throw({missing_token_or_regid, Notification})
            end,
            {registration_ids, RIs};
        _ ->
            throw({missing_token_or_regid, Notification})
    end.

store_props(FromProps, ToProps) ->
    lists:foldl(fun({K, _V} = KV, Acc) -> lists:keystore(K, 1, Acc, KV) end,
                ToProps, FromProps).
