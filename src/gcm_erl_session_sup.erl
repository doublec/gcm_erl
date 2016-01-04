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
%%% @doc
%%% GCM session supervisor behavior callback module.
%%% @end
%%%-------------------------------------------------------------------
-module(gcm_erl_session_sup).

-behaviour(supervisor).

%% API
-export([
          start_link/1
        , start_child/2
        , stop_child/1
        , is_child_alive/1
        , get_child_pid/1
    ]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

-include_lib("lager/include/lager.hrl").

%% ===================================================================
%% API functions
%% ===================================================================

start_link(Sessions) when is_list(Sessions) ->
    case supervisor:start_link({local, ?SERVER}, ?MODULE, []) of
        {ok, _Pid} = Res ->
            % Start children
            _ = [{ok, _} = start_child(Opts) || Opts <- Sessions],
            Res;
        Error ->
            Error
    end.

start_child(Name, Opts) when is_atom(Name), is_list(Opts) ->
    supervisor:start_child(?SERVER, [Name, Opts]).

stop_child(Name) when is_atom(Name) ->
    case get_child_pid(Name) of
        Pid when is_pid(Pid) ->
            supervisor:terminate_child(?SERVER, Pid);
        undefined ->
            {error, not_started}
    end.

is_child_alive(Name) when is_atom(Name) ->
    get_child_pid(Name) =/= undefined.

get_child_pid(Name) when is_atom(Name) ->
    erlang:whereis(Name).

%%====================================================================
%% Internal functions
%%====================================================================

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    Session = {
        gcm_erl_session,
        {gcm_erl_session, start_link, []},
        transient,
        brutal_kill,
        worker,
        [gcm_erl_session]
    },
    Children = [Session],
    MaxR = 20,
    MaxT = 20,
    RestartStrategy = {simple_one_for_one, MaxR, MaxT},
    {ok, {RestartStrategy, Children}}.


start_child(Opts) ->
    _ = lager:info("Starting GCM session with opts: ~p", [Opts]),
    Name = sc_util:req_val(name, Opts),
    SessCfg = sc_util:req_val(config, Opts),
    start_child(Name, SessCfg).

