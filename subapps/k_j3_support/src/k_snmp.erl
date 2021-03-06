-module(k_snmp).

-behaviour(gen_fsm).

-include_lib("k_common/include/logging.hrl").
-include_lib("k_common/include/gen_fsm_spec.hrl").
-include("snmp_task.hrl").

-define(USER, "user").
-define(TARGET, "just").

-define(destroy, 6).
-define(createAndWait, 5).
-define(createAndGo, 4).
-define(notReady, 3).
-define(notInService, 2).
-define(active, 1).

%% API
-export([
	start_link/0,
	get_column_val/2,
	set_row/3,
	del_row/2
]).

%% Callbacks
-export([
	init/1,

	ready/2,
	ready/3,
	sleep/2,
	sleep/3,

	handle_event/3,
	handle_sync_event/4,
	handle_info/3,
	terminate/3,
	code_change/4
]).

-record(state, {
	time = 10000 :: integer()
}).

-record(varbind, {
	oid 	:: list(),
	type 	:: atom(),
	value 	:: term(),
	int 	:: integer()
}).

%%% --- API ---

-spec start_link() -> {ok, pid()}.
start_link() ->
	{ok, Pid} = gen_fsm:start_link({local, ?MODULE}, ?MODULE, [], []),
	process_queue(),
	{ok, Pid}.

-spec get_column_val(snmp_column_name(), snmp_index()) -> snmp_result().
get_column_val(ColumnName, Index) ->
	{ok, [OID]} = snmpm:name_to_oid(ColumnName),
	Result = snmpm:sync_get(?USER, ?TARGET, [OID ++ Index]),
	%?log_debug("Get result: ~p", [Result]),
	parse_snmp_result(Result).

-spec set_row(snmp_column_name(), snmp_index(), snmp_value_list()) -> ok.
set_row(TableName, Index, ValueList) ->
	Task = #task{function = fun set_row/1, args = {TableName, Index, ValueList}},
	process_task(Task).

-spec del_row(snmp_column_name(), snmp_index()) -> ok.
del_row(TableName, Index)->
	Task = #task{function = fun del_row/1, args = {TableName, Index}},
	process_task(Task).

%%% Callbacks

init(_Args) ->
	{ok, ready, #state{}}.

sleep(process_queue, State = #state{}) ->
	{next_state, sleep, State};
sleep(wake_up, State = #state{}) ->
	process_queue(),
	{next_state, ready, State};
sleep(Event, State = #state{}) ->
	{stop, {bad_event, Event}, State}.

ready(process_queue, State = #state{time = Time}) ->
	case next() of
	{ok, #task{id = Id, function = Fun, args = Args}} ->
		case Fun(Args) of
			{ok, ok} ->
				ack(Id),
				process_queue(),
				{next_state, ready, State};
			Error ->
				%?log_error("error process snmp task: ~p", [Error]),
				%?log_debug("going to sleep...", []),
				start_timer(Time),
				{next_state, sleep, State}
		end;
	{ok, []} ->
		{next_state, ready, State}
	end;
ready(Event, State = #state{}) ->
	{stop, {bad_event, Event}, State}.

sleep(Event, _From, State) ->
	{stop, {bad_sync_event, Event}, State}.

ready(Event, _From, State) ->
	{stop, {bad_sync_event, Event}, State}.

handle_event(Event, _StateName, State = #state{}) ->
	{stop, {bad_event, Event}, State}.

handle_sync_event(Event, _From, _StateName, State = #state{}) ->
	{stop, {bad_sync_event, Event}, State}.

handle_info(_Info, StateName, State = #state{}) ->
	{next_state, StateName, State}.

terminate(_Reason, _StateName, _State = #state{}) ->
	ok.

code_change(_OldVsn, StateName, State = #state{}, _Extra) ->
	{ok, StateName, State}.


%%% --- Internal Functions ---

%%% Queue functions

next() ->
	k_snmp_tasks_queue:next().

save_task(Task) ->
	k_snmp_tasks_queue:save(Task).

ack(Id) ->
	k_snmp_tasks_queue:ack(Id).
%%%

start_timer(Time) ->
	{ok, _TRef} = timer:apply_after(Time, gen_fsm, send_event, [?MODULE, wake_up]).

process_queue() ->
	gen_fsm:send_event(?MODULE, process_queue).

process_task(Task) ->
	save_task(Task),
	process_queue().

set_row({TableName, Index, ValueList}) ->
	case is_exist(TableName, Index) of
		exist -> update(Index, ValueList);
		notExist -> create(TableName, Index, ValueList);
		incorrectState -> recreate(TableName, Index, ValueList);
		Any -> Any
	end.

del_row({TableName, Index}) ->
	case TableName of
		gtw ->
			set(Index, [{gtwStatus, ?destroy}]);
		sts ->
			set(Index, [{stsStatus, ?destroy}]);
		cst ->
			set(Index, [{cstStatus, ?destroy}]);
		cnn ->
			set(Index, [{cnnStatus, ?destroy}]);
		_Any ->
			{error, noSuchTable}
	end.


recreate(TableName, Index, ValueList) ->
	del_row({TableName, Index}),
	create(TableName, Index, ValueList).

create(TableName, Index, ValueList) ->
	case TableName of
		gtw ->
			update(Index, [{gtwStatus, ?createAndWait}] ++ ValueList ++ [{gtwStatus, ?active}]);
		sts ->
			update(Index, [{stsStatus, ?createAndWait}] ++ ValueList ++ [{stsStatus, ?active}]);
		cst ->
			update(Index, [{cstStatus, ?createAndWait}] ++ ValueList ++ [{cstStatus, ?active}]);
		cnn ->
			update(Index, [{cnnStatus, ?createAndWait}] ++ ValueList ++ [{cnnStatus, ?active}]);
		_Any ->
			{error, noSuchTable}
	end.

update(Index, ValueList) ->
	set(Index, ValueList).


set(Index, ValueList) ->
	set(Index, ValueList, _InitResult = {ok, init}).

set(_Index, _ValueList = [], _LastResult = {ok, _}) ->
	{ok, ok};
set(Index, [{ColumnName, Value} | RestValueList], _LastResult = {ok, _}) ->
	{ok, [OID]} = snmpm:name_to_oid(ColumnName),
	Result = snmpm:sync_set(?USER, ?TARGET, [{OID ++ Index, Value}]),
	%?log_debug("snmp result: ~p", [Result]),
	set(Index, RestValueList, parse_snmp_result(Result));
set(_Index, _ValueList, ErrorResult) ->
	%?log_error("snmp set error: ~p", [ErrorResult]),
	{error, ErrorResult}.

is_exist(TableName, Index)->
	{ok, ColumnName} = status_column_name(TableName),
	GetResult = get_column_val(ColumnName, Index),
	%?log_debug("GetResult: ~p", [GetResult]),
	case GetResult of
		{ok, ?active} -> exist;
		{ok, Some} when is_integer(Some) -> incorrectState;
		{error, {timeout, T}} -> {error, {timeout, T}};
		{_Error, _More} -> notExist
	end.

status_column_name(TableName) ->
	case TableName of
		gtw -> {ok, gtwStatus};
		sts -> {ok, stsStatus};
		cst -> {ok, cstStatus};
		cnn -> {ok, cnnStatus};
		_Any -> {error, noSuchTable}
	end.

parse_snmp_result(Result) ->
	%?log_debug("Snmp result: ~p", [Result]),
	case Result of
		{ok, { noError, 0, [#varbind{value = Value}]}, _Remaining} ->
			case Value of
				noSuchObject ->
					{error, noSuchObject};
				noSuchInstance ->
					{error, noSuchInstance};
				AnyValue->
					{ok, AnyValue}
			end;
		{ok, {ErState, _ErInd, _Varbind}, _Remaining} ->
			{error, ErState};
		{error, Reason} ->
			{error, Reason}
	end.
