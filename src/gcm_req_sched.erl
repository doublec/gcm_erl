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
%%% This module is the request scheduler. Its purpose is to store and
%%% resubmit delayed GCM requests at some future time. For performance
%%% reasons, it does not store notifications on disk, so a shutdown
%%% or crash will lose notifications that were to have been resubmitted.
%%%
%%% GCM notifications may be delayed because the GCM server was busy
%%% or temporarily unavailable.
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(gcm_req_sched).

-behaviour(gen_server).

%% API
-export([
        start_link/0,
        start/0,
        stop/0,
        add/4,
        del/1,
        get/1,
        clear_all/0,
        run_sweep/0
    ]).

%% gen_server callbacks
-export([init/1,
        handle_call/3,
        handle_cast/2,
        handle_info/2,
        terminate/2,
        code_change/3]).

-define(SERVER, ?MODULE).
-define(TAB, ?MODULE).
-define(TIMER_TICK, 1000). % Tick every second

-type terminate_reason() :: normal |
                            shutdown |
                            {shutdown, term()} |
                            term().

-type mspec() :: '_'. % Match specs set unused record fields to '_'.

-record(state, {
        timer_ref :: reference()
    }).

-record(req, {
        id = {}          :: any(),
        trigger_time = 1 :: pos_integer() | mspec(),
        data = {}        :: any(),
        dest_pid         :: pid() | mspec()
    }).

-include_lib("stdlib/include/ms_transform.hrl").

%%%===================================================================
%%% API
%%%===================================================================
%%--------------------------------------------------------------------
%% @doc Add data with unique id to be triggered at a POSIX time
%% to send the data to pid.
%% `Data' is sent to `Pid' as `{triggered, {ReqId, Data}}'.
%%--------------------------------------------------------------------
-spec add(any(), pos_integer(), any(), pid()) -> ok.
add(Id, TriggerTime, Data, Pid) when is_integer(TriggerTime), is_pid(Pid)  ->
    gen_server:call(?SERVER, {add, {Id, TriggerTime, Data, Pid}}).

%%--------------------------------------------------------------------
%% @doc Delete data with given id.
%%--------------------------------------------------------------------
-spec del(any()) -> ok.
del(Id) ->
    gen_server:call(?SERVER, {del, Id}).

%%--------------------------------------------------------------------
%% @doc Retrieve data with given id, and return `{TriggerTime, Data}', or
%% `notfound'. `TriggerTime' is POSIX time.
%%--------------------------------------------------------------------
-spec get(any()) -> {ok, {TriggerTime::pos_integer(), Data::any}} | notfound.
get(Id) ->
    gen_server:call(?SERVER, {get, Id}).

%%--------------------------------------------------------------------
%% @doc Clear all entries.
%%--------------------------------------------------------------------
-spec clear_all() -> ok.
clear_all() ->
    gen_server:call(?SERVER, clear_all).

%%--------------------------------------------------------------------
%% @doc Force a sweep of all data to trigger matching messages.
%%--------------------------------------------------------------------
-spec run_sweep() -> ok.
run_sweep() ->
    gen_server:cast(?SERVER, run_sweep),
    ok.

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @end
%%--------------------------------------------------------------------
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec start() -> {ok, pid()} | ignore | {error, term()}.
start() ->
    gen_server:start({local, ?SERVER}, ?MODULE, [], []).

%%--------------------------------------------------------------------
%% @doc Stops the server - for testing only.
%%--------------------------------------------------------------------
-spec stop() -> ok.
stop() ->
    gen_server:cast(?SERVER, stop).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @end
%%--------------------------------------------------------------------
-spec init(term()) -> {ok, State::term()} |
                      {ok, State::term(), Timeout::timeout()} |
                      {ok, State::term(), 'hibernate'} |
                      {stop, Reason::term()} |
                      'ignore'
                      .
init([]) ->
    _ = create_tables(),
    {ok, #state{
            timer_ref = create_timer(?TIMER_TICK, self(), timer_tick)
           }}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @end
%%--------------------------------------------------------------------
-spec handle_call(Request::term(),
                  From::{pid(), Tag::term()},
                  State::term()) ->
    {reply, Reply::term(), NewState::term()} |
    {reply, Reply::term(), NewState::term(), Timeout::timeout()} |
    {reply, Reply::term(), NewState::term(), 'hibernate'} |
    {noreply, NewState::term()} |
    {noreply, NewState::term(), 'hibernate'} |
    {noreply, NewState::term(), Timeout::timeout()} |
    {stop, Reason::term(), Reply::term(), NewState::term()} |
    {stop, Reason::term(), NewState::term()}
    .

handle_call({add, {Id, TriggerTime, Data, Pid}}, _From, State) ->
    Reply = add_impl(Id, TriggerTime, Data, Pid),
    {reply, Reply, State};
handle_call({del, Id}, _From, State) ->
    Reply = del_impl(Id),
    {reply, Reply, State};
handle_call({get, Id}, _From, State) ->
    Reply = get_impl(Id),
    {reply, Reply, State};
handle_call(clear_all, _From, State) ->
    Reply = clear_all_impl(),
    {reply, Reply, State};
handle_call(_Request, _From, State) ->
    Reply = {error, bad_request},
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
-spec handle_cast(Request::term(),
                  State::term()) ->
    {noreply, NewState::term()} |
    {noreply, NewState::term(), 'hibernate'} |
    {noreply, NewState::term(), Timeout::timeout()} |
    {stop, Reason::term(), NewState::term()}
    .

handle_cast(stop, State) ->
    {stop, normal, State};
handle_cast(run_sweep, State) ->
    self() ! timer_tick,
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @end
%%--------------------------------------------------------------------
-spec handle_info(Request::term(),
                  State::term()) ->
    {noreply, NewState::term()} |
    {noreply, NewState::term(), 'hibernate'} |
    {noreply, NewState::term(), Timeout::timeout()} |
    {stop, Reason::term(), NewState::term()}
    .
handle_info(timer_tick, State) ->
    _ = cancel_timer(State#state.timer_ref),
    schedule_requests(),
    NewTimer = create_timer(?TIMER_TICK, self(), timer_tick),
    NewState = State#state{timer_ref = NewTimer},
    {noreply, NewState};
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @end
%%--------------------------------------------------------------------
-spec terminate(Reason::terminate_reason(),
                State::term()) -> no_return().
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @end
%%--------------------------------------------------------------------
-spec code_change(OldVsn::term() | {down, term()},
                  State::term(),
                  Extra::term()) ->
    {ok, NewState::term()} |
    {error, Reason::term()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
add_impl(Id, TriggerTime, Data, Pid) when is_integer(TriggerTime),
                                          is_pid(Pid) ->
    Req = #req{id = Id,
               trigger_time = TriggerTime,
               data = Data,
               dest_pid = Pid},
    ets:insert(?TAB, Req),
    ok.

del_impl(Id) ->
    ets:delete(?TAB, Id),
    ok.

get_impl(Id) ->
    case ets:lookup(?TAB, Id) of
        [#req{trigger_time = T, data = Data}] ->
            {ok, {T, Data}};
        [] ->
            notfound
    end.

clear_all_impl() ->
    ets:delete_all_objects(?TAB),
    ok.

create_timer(IntervalMs, DestPid, Msg) ->
    erlang:send_after(IntervalMs, DestPid, Msg).

cancel_timer(undefined) ->
    false;
cancel_timer(TimerRef) ->
    erlang:cancel_timer(TimerRef).

create_tables() ->
    ets:new(?MODULE, [set, protected, named_table, {keypos, #req.id}]).

schedule_requests() ->
    Now = sc_util:posix_time(),
    TriggeredMatchSpec = ets:fun2ms(
        fun(#req{} = R) when R#req.trigger_time =< Now -> R end
    ),

    [
        begin
                R#req.dest_pid ! {triggered, {R#req.id, R#req.data}},
                ets:delete(?TAB, R#req.id)
        end || R <- ets:select(?TAB, TriggeredMatchSpec)
    ],
    ok.

%% vim: ts=4 sts=4 sw=4 et tw=80

