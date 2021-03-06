-module(k_funnel_events_handler).

-export([process/2]).

-include("amqp_worker_reply.hrl").
-include_lib("k_common/include/logging.hrl").
-include_lib("k_common/include/FunnelAsn.hrl").
-include_lib("k_common/include/storages.hrl").

-spec process(binary(), binary()) -> {ok, [#worker_reply{}]} | {error, any()}.
process(<<"ConnectionDownEvent">>, Message) ->
	case 'FunnelAsn':decode('ConnectionDownEvent', Message) of
		{ok, #'ConnectionDownEvent'{
			connectionId = ConnId,
			customerId = SystemId
		}} ->
			process_connection_down_event(ConnId, SystemId);
		{error, Error} ->
			?log_error("Failed to decode ConnectionDownEvent: ~p with error: ~p", [Message, Error]),
			{ok, []}
	end;

process(<<"ConnectionUpEvent">>, Message) ->
	case 'FunnelAsn':decode('ConnectionUpEvent', Message) of
		{ok, #'ConnectionUpEvent'{
			connectionId = ConnId,
			customerId = SystemId,
			type = ConnType
		}} ->
			process_connection_up_event(ConnId, SystemId, ConnType);
		{error, Error} ->
			?log_error("Failed to decode ConnectionUpEvent: ~p with error: ~p", [Message, Error]),
			{ok, []}
	end;

process(_Any, _Message) -> {ok, []}.


%%% Internal

process_connection_down_event(ConnId, SystemId) ->
	case resolve_cust_id(SystemId) of
		{ok, CustId} ->
			perform_unregister_connection(CustId, ConnId);
		{error, no_entry} ->
			?log_error("Could not unregister: failed to resolve [system-id: ~p]", [SystemId]),
			{ok, []}
	end.

perform_unregister_connection(CustId, ConnId) ->
	case k_mailbox:unregister_connection(CustId, ConnId) of
		ok ->
			{ok, []};
		{error, Error} ->
			?log_error("Could not unregister ~p due to: ~p", [{CustId, ConnId}, Error]),
			% {error, Error}
			{ok, []}
	end.

process_connection_up_event(ConnId, SystemId, ConnType) ->
	case resolve_cust_id(SystemId) of
		{ok, CustId} ->
			k_mailbox:register_connection(CustId, ConnId, conn_type_to_cannonical(ConnType)),
			{ok, []};
		{error, no_entry} ->
			?log_error("Could not register: failed to resolve [system-id: ~p]", [SystemId]),
			{ok, []}
	end.

resolve_cust_id( SystemId ) ->
	case k_aaa_api:get_customer_by_system_id(SystemId) of
			{ok, #customer{
			uuid = CustId
		}} -> {ok, CustId};
		Error -> Error
	end.

conn_type_to_cannonical(transmitter) -> 'smpp.transmitter';
conn_type_to_cannonical(transceiver) -> 'smpp.transceiver';
conn_type_to_cannonical(receiver) -> 'smpp.receiver'.
