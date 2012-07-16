-module(k_incoming_sms_handler).

-export([process/2]).

-include_lib("k_common/include/logging.hrl").
-include_lib("k_common/include/JustAsn.hrl").
-include_lib("k_mailbox/include/address.hrl").
-include("amqp_worker_reply.hrl").

-spec process(binary(), binary()) -> {ok, [#worker_reply{}]} | {error, any()}.
process(<<"IncomingSm">>, Message) ->
	%?log_debug("Got message: ~p", [Message]),
	case 'JustAsn':decode('IncomingSm', Message) of
		{ok, IncomingSmsRequest} ->
			process_incoming_sms_request(IncomingSmsRequest);
		Error ->
			Error
	end;

process(CT, Message) ->
	?log_warn("Got unexpected message of type ~p: ~p", [CT, Message]),
	{ok, []}.

process_incoming_sms_request(IncomingSmsRequest = #'IncomingSm'{
	source = SourceFullAddr,
	dest = DestFullAddr,
	message = MessageBody,
	dataCoding = DataCoding
}) ->
	?log_debug("Got request: ~p", [IncomingSmsRequest]),
	#'FullAddr'{
		addr = Addr,
		ton = TON,
		npi = NPI
	} = DestFullAddr,
	case k_addr2cust:resolve(#addr{addr=Addr, ton=TON, npi=NPI}) of
		{ok, CID, UserID} ->
			?log_debug("Got incoming message for [cust:~p; user: ~p] (addr:~p, ton:~p, npi:~p)", [CID, UserID, Addr, TON, NPI] ),
			DC = case DataCoding of
				0 -> {text, gsm0338};
				8 -> {text, ucs2};
				_ -> {other, DataCoding}
			end,
			ItemID = k_uuid:to_string(k_uuid:newid()),
			?log_debug("Incomming message registered [item:~p]", [ItemID]),
			k_mailbox:register_incoming_item(
				ItemID,
				CID, UserID, <<"OutgoingBatch">>,
				k_funnel_asn_helper:render_outgoing_batch(
					ItemID, SourceFullAddr,
					DestFullAddr, MessageBody, DC
				));
	    Result ->
			?log_debug("Resolve result: ~p", [Result]),
			?log_debug("Could not resolve incoming message to (addr:~p, ton:~p, npi:~p)", [Addr, TON, NPI])
	end,
	{ok, []}.
