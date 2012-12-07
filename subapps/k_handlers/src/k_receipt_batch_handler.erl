-module(k_receipt_batch_handler).

-export([process/2]).

-include("amqp_worker_reply.hrl").
-include_lib("k_common/include/msg_id.hrl").
-include_lib("k_common/include/msg_info.hrl").
-include_lib("k_common/include/msg_status.hrl").
-include_lib("k_common/include/logging.hrl").
-include_lib("alley_dto/include/adto.hrl").
-include_lib("k_mailbox/include/application.hrl").

%% ===================================================================
%% API
%% ===================================================================

-spec process(binary(), binary()) -> {ok, [#worker_reply{}]} | {error, any()}.
process(<<"ReceiptBatch">>, Message) ->
	case adto:decode(#just_delivery_receipt_dto{}, Message) of
		{ok, ReceiptBatch} ->
			process_receipt_batch(ReceiptBatch);
		Error ->
			Error
	end;

process(ContentType, Message) ->
	?log_warn("Got unexpected message of type ~p: ~p", [ContentType, Message]),
	{ok, []}.

%% ===================================================================
%% Internal
%% ===================================================================

-spec process_receipt_batch(#just_delivery_receipt_dto{}) -> {ok, [#worker_reply{}]} | {error, any()}.
process_receipt_batch(ReceiptBatch = #just_delivery_receipt_dto{
	gateway_id = GatewayId,
	receipts = Receipts
}) ->
	?log_debug("Got just delivery receipt: ~p", [ReceiptBatch]),
	DlrTime = k_datetime:utc_unix_epoch(),
	case traverse_delivery_receipts(GatewayId, DlrTime, Receipts) of
		ok ->
			{ok, []};
		%% abnormal case, either sms request or response isn't handled yet, or both.
		{error, no_entry} ->
			{error, not_enough_data_to_proceed};
		Error ->
			Error
	end.

traverse_delivery_receipts(_GatewayId, _DlrTime, []) ->
	ok;
traverse_delivery_receipts(GatewayId, DlrTime,
	[#just_receipt_dto{message_id = MessageId, message_state = MessageState} | Receipts]) ->
	OutputId = {GatewayId, MessageId},
	case k_storage:get_input_id_by_output_id(OutputId) of
		{ok, InputId} ->
			?log_debug("[out:~p] -> [in:~p]", [OutputId, InputId]),
			case k_storage:get_msg_info(InputId) of
				{ok, MsgInfo} ->
					case update_delivery_state(InputId, OutputId, MsgInfo, DlrTime, MessageState) of
						ok ->
							case register_delivery_receipt(InputId, MsgInfo, DlrTime, MessageState) of
								ok ->
									traverse_delivery_receipts(GatewayId, DlrTime, Receipts);
								Error ->
									Error
							end;
						Error ->
							Error
					end;
				Error ->
					Error
			end;
		Error ->
			Error
	end.

update_delivery_state(InputId, OutputId, MsgInfo, DlrTime, MessageState) ->
	case k_storage:get_msg_status(InputId) of
		{ok, MsgStatus} ->
			NewMsgStatus = MsgStatus#msg_status{
				status = MessageState,
				dlr_time = DlrTime
			},
			ok = k_storage:set_msg_status(InputId, NewMsgStatus),
			ok = k_statistic:store_status_stats(InputId, OutputId, MsgInfo, NewMsgStatus, DlrTime);
		Error ->
			Error
	end.

register_delivery_receipt(InputId, MsgInfo, DlrTime, MessageState) ->
	{_CustomerId, ClientType, _InputMsgId} = InputId,
	{ok, Item} = build_receipt_item(ClientType, InputId, MsgInfo, DlrTime, MessageState),
	ok = k_mailbox:register_incoming_item(Item).

build_receipt_item(k1api, InputId, MsgInfo, _DlrTime, MsgState) ->
	SourceAddr = MsgInfo#msg_info.src_addr,
	DestAddr = MsgInfo#msg_info.dst_addr,
	{CustomerId, _ClientType, InputMsgId} = InputId,
	UserId = <<"undefined">>,
	ItemId = uuid:newid(),
	Item = #k_mb_k1api_receipt{
		id = ItemId,
		customer_id	= CustomerId,
		user_id	= UserId,
		source_addr = convert_addr(SourceAddr),
		dest_addr = convert_addr(DestAddr),
		input_message_id = InputMsgId,
		message_state = MsgState
	},
	{ok, Item};
build_receipt_item(funnel, InputId, MsgInfo, DlrTime, MsgState) ->
	SenderAddr = MsgInfo#msg_info.src_addr,
	DestAddr = MsgInfo#msg_info.dst_addr,
	{CustomerId, _ClientType, InputMsgId} = InputId,
	UserId = <<"undefined">>,
	ItemId = uuid:newid(),
	Item = #k_mb_funnel_receipt{
		id = ItemId,
		customer_id	= CustomerId,
		user_id = UserId,
		source_addr = convert_addr(SenderAddr),
		dest_addr = convert_addr(DestAddr),
		input_message_id = InputMsgId,
		submit_date = DlrTime,
		done_date = DlrTime,
		message_state = MsgState
	 },
	{ok, Item}.

convert_addr(undefined) ->
	undefined;
convert_addr(Addr = #full_addr{}) ->
	#full_addr{
		addr = Msisdn,
		ton = TON,
		npi = NPI
	} = Addr,
	#addr{
		addr = Msisdn,
		ton = TON,
		npi = NPI
	};
convert_addr(Addrs) ->
	[convert_addr(Addr) || Addr <- Addrs].
