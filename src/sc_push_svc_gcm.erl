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
%%% == Session Configuration ==
%%%
%%% Start the API by calling start_link/1 and providing a list of
%%% sessions to start. Each session is a proplist as shown below:
%%%
%%% ```
%%% [
%%%     {name, 'gcm-com.example.MyApp'},
%%%     {config, [
%%%             {api_key, <<"AIzaffffffffffffffffffffffffffffffff73w">>},
%%%             {ssl_opts, [{verify, verify_none}]},
%%%             {uri, "https://fcm.googleapis.com/fcm/send"},
%%%             {max_attempts, 5},
%%%             {retry_interval, 1},
%%%             {max_req_ttl, 600}
%%%         ]}
%%% ]
%%% '''
%%%
%%% Note that the session <em>must</em> be named `gcm-{AppId}',
%%% where `{AppId}' is the Android App ID, such as
%%% `com.example.MyApp'.
%%%
%%% == Sending an alert via the sc_push API ==
%%%
%%% At the top level, alerts are sent via sc_push. Here is an example of
%%% an alert that directly specifies the receivers (only one in this case)
%%% and some gcm-specific options:
%%%
%%% ```
%%% Alert = <<"Hello, Android!">>,
%%% RegId = <<"dQMPBffffff:APA91bbeeff...8yC19k7ULYDa9X">>,
%%% AppId = <<"com.example.MyApp">>,
%%%
%%% Nf = [{alert, Alert},
%%%       {receivers,[{svc_appid_tok, [{gcm, AppId, RegId}]}]},
%%%       {gcm, [{priority, <<"high">>}, {collapse_key, <<"true">>}]}],
%%%
%%% [{ok, Ref}] = gcm_erl:send(Nf).
%%% '''
%%%
%%% Note that the same alert may be sent to multiple receivers, in which
%%% case there will be multiple return values (one per notification sent):
%%%
%%% ```
%%% Alert = <<"Hello, Android!">>,
%%% RegId1 = <<"dQMPBffffff:APA91bbeeff...8yC19k7ULYDa9X">>,
%%% RegId2 = <<"dQMPBeeeeee:APA91dddddd...8yCefefefefefe">>,
%%% AppId = <<"com.example.MyApp">>,
%%% Receivers = [{svc_appid_tok,[{gcm, AppId, RegId1},{gcm, AppId, RegId2}]}],
%%%
%%% Nf = [{alert,<<"Please register">>},
%%%       {receivers, Receivers},
%%%       {gcm, [{priority, <<"high">>}, {collapse_key, <<"true">>}]}],
%%%
%%% [{ok, Ref,}, {ok, Ref2}] = gcm_erl:send(Nf).
%%%
%%% In the same way, an alert may be sent to receivers on different services
%%% and using different receiver types, such as `tag'.
%%%
%%% === Sending an alert via the gcm_erl API ===
%%%
%%% ```
%%% Alert = <<"Hello, Android!">>,
%%% {ok, SeqNo} = gcm_erl:send('gcm-com.example.MyApp', Nf).
%%% '''
%%%
%%% === Sending an alert via a session ===
%%%
%%% ```
%%% Nf = [{id, sc_util:to_bin(RegId)},
%%%       {data, [{alert, sc_util:to_bin(Msg)}]}],
%%% {ok, SeqNo} = gcm_erl_session:send('gcm-com.example.MyApp', Nf).
%%% '''
%%%
%%% Note that the above notification is semantically identical to
%%%
%%% ```
%%% Nf = [{registration_ids, [sc_util:to_bin(RegId)]},
%%%       {data, [{alert, sc_util:to_bin(Msg)]}].
%%% '''
%%%
%%% It follows that you can send to multiple registration ids:
%%%
%%% ```
%%% BRegIds = [sc_util:to_bin(RegId) || RegId <- RegIds],
%%% Nf = [{registration_ids, BRegIds},
%%%       {data, [{alert, sc_util:to_bin(Msg)}]}],
%%% Rsps = gcm_erl_session:send('gcm-com.example.MyApp', Nf).
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
-include("gcm_erl_internal.hrl").

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
         async_send/3,
         async_send_cb/5
        ]).

%% Supervisor callbacks
-export([init/1]).

%% Internal exports
-export([
         normalize_alert/1,
         normalize_data/1,
         normalize_id/1,
         normalize_reg_ids/1,
         normalize_token/1
        ]).

-import(lists, [keydelete/3, keystore/4]).

%% ===================================================================
%% Types
%% ===================================================================
-type notification() :: proplists:proplist().
-type cb_req() :: proplists:proplist().
-type cb_resp() :: {ok, term()} | {error, term()}.
-type callback() :: fun((notification(), cb_req(), cb_resp()) -> any()).
-type async_send_result() :: {ok, {submitted, uuid()}} | {error, term()}.
-type uuid() :: uuid:uuid_str().

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
%% @doc Send a notification specified by proplist `Nf'
%% @end
%%--------------------------------------------------------------------
send(Name, Nf) when is_list(Nf) ->
    send(sync, Name, Nf, []).

%%--------------------------------------------------------------------
%% @doc Send a notification specified by proplist `Nf' and
%% with options `Opts'.
%% @see gcm_erl_session:send/3.
%% @end
%%--------------------------------------------------------------------
send(Name, Nf, Opts) when is_list(Nf), is_list(Opts) ->
    send(sync, Name, Nf, Opts).

%%--------------------------------------------------------------------
%% @doc Asynchronously send a notification specified by proplist
%% `Nf'; Same as {@link send/2} beside returning only 'ok' on success.
%% @end
%%--------------------------------------------------------------------
async_send(Name, Nf) when is_list(Nf) ->
    send(async, Name, Nf, []).

%%--------------------------------------------------------------------
%% @doc Asynchronously send a notification specified by proplist
%% `Nf' with options `Opts'. `Opts' is currently unused.
%% @end
%%--------------------------------------------------------------------
async_send(Name, Nf, Opts) when is_list(Nf), is_list(Opts) ->
    send(async, Name, Nf, Opts).

%%--------------------------------------------------------------------
%% @doc Asynchronously send a notification specified by proplist
%% `Nf'
%% @end
%%--------------------------------------------------------------------
-spec async_send_cb(Name, Nf, Opts, ReplyPid, Cb) -> Result when
      Name :: term(), Nf :: notification(), Opts :: list(),
      ReplyPid :: pid(), Cb :: callback(),
      Result :: async_send_result().
async_send_cb(Name, Nf0, Opts, ReplyPid, Cb) when is_list(Nf0),
                                                  is_list(Opts),
                                                  is_pid(ReplyPid),
                                                  is_function(Cb, 3) ->
    _ = ?LOG_DEBUG("Name: ~p, Nf0: ~p~n"
                   "Opts: ~p, ReplyPid: ~p, Cb: ~p",
                   [Name, Nf0, Opts, ReplyPid, Cb]),
    case try_normalize_nf(Nf0) of
        {ok, Nf} ->
            _ = ?LOG_DEBUG("Normalized nf: ~p", [Nf]),
            gcm_erl_session:async_send_cb(Name, Nf, Opts, ReplyPid, Cb);
        Error ->
            Error
    end.

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init(Opts) ->
    ?LOG_INFO("Starting service with opts: ~p",
              [gcm_erl_util:sanitize_opts(Opts)]),
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
send(Mode, Name, Nf0, Opts) when (Mode == sync orelse Mode == async) andalso
                                 is_list(Nf0) andalso is_list(Opts) ->
    _ = ?LOG_DEBUG("Mode: ~p, Name: ~p, Nf: ~p, Opts: ~p",
                   [Mode, Name, Nf0, Opts]),
    case try_normalize_nf(Nf0) of
        {ok, Nf} ->
            (send_fun(Mode))(Name, Nf, Opts);
        Error ->
            Error
    end.

%%--------------------------------------------------------------------
send_fun(sync)  -> fun gcm_erl_session:send/3;
send_fun(async) -> fun gcm_erl_session:async_send/3.

%%--------------------------------------------------------------------
try_normalize_nf(Nf) ->
    try
        {ok, normalize_nf(Nf)}
    catch
        throw:{missing_one_of, {_Nf, Keys}}=Exc ->
            ?LOG_ERROR("Stacktrace:~s", [?STACKTRACE(throw, Exc)]),
            {error, {missing_one_of_keys, Keys}}
    end.

%%--------------------------------------------------------------------
normalize_nf(Nf) ->
    normalize_alert_data(normalize_destination(Nf)).

%%--------------------------------------------------------------------
normalize_alert_data(Nf) ->
    find_first(Nf, [fun normalize_data/1,
                    fun normalize_alert/1,
                    missing_key_error_fun([data, alert])]).

%%--------------------------------------------------------------------
normalize_destination(Nf) ->
    find_first(Nf, [fun normalize_id/1,
                    fun normalize_token/1,
                    fun normalize_reg_ids/1,
                    missing_key_error_fun([id, token, registration_ids])]).

%%--------------------------------------------------------------------
normalize_alert(Nf) ->
    case sc_util:val(alert, Nf) of
        Alert when is_binary(Alert) orelse is_list(Alert) ->
            keystore(data, 1, keydelete(alert, 1, Nf),
                     {data, [{alert, sc_util:to_bin(Alert)}]});
        undefined ->
            false
    end.

%%--------------------------------------------------------------------
normalize_data(Nf) ->
    case sc_util:val(data, Nf) of
        Data when is_list(Data) ->
            keydelete(alert, 1, Nf);
        undefined ->
            false
    end.

%%--------------------------------------------------------------------
normalize_id(Nf) ->
    case sc_util:val(id, Nf) of
        Id when is_binary(Id) orelse is_list(Id) ->
            keystore(id, 1,
                     delete_props([token, receivers, registration_ids], Nf),
                     {id, sc_util:to_bin(Id)});
        undefined ->
            false
    end.

%%--------------------------------------------------------------------
normalize_token(Nf) ->
    case sc_util:val(token, Nf) of
        Id when is_binary(Id) orelse is_list(Id) ->
            keystore(id, 1,
                     delete_props([token, receivers, registration_ids], Nf),
                     {id, sc_util:to_bin(Id)});
        undefined ->
            false
    end.

%%--------------------------------------------------------------------
normalize_reg_ids(Nf) ->
    case sc_util:val(registration_ids, Nf) of
        [RId|_] when is_binary(RId) orelse is_list(RId) ->
            delete_props([id, token, receivers], Nf);
        _ ->
            false
    end.

%%--------------------------------------------------------------------
missing_key_error_fun(Keys) ->
    fun(Nf) ->
        throw({missing_one_of, {Nf, Keys}})
    end.

%%--------------------------------------------------------------------
delete_props(Keys, Props) ->
    lists:foldl(fun(K, Acc) -> lists:keydelete(K, 1, Acc) end, Props, Keys).

%%--------------------------------------------------------------------
%% Preds is list of fun/1.
%% Each fun takes Data and returns either false or transformed Data.
find_first(Data, Preds) when is_list(Preds) ->
    ?LOG_DEBUG("Preds: ~p~nData: ~p", [Preds, Data]),
    try
        lists:foldl(fun(Pred, _Acc) when is_function(Pred, 1) ->
                            case Pred(Data) of
                                false ->
                                    false;
                                X ->
                                    throw({found, X})
                            end
                    end, false, Preds)
    catch
        throw:{found, X} ->
            X
    end.


