-module(k_j3_support_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

-include("application.hrl").
-include_lib("k_common/include/application_spec.hrl").
-include_lib("k_common/include/logging.hrl").

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
	register(?MODULE, self()),
	k_j3_support_sup:start_link().

stop(_State) ->
	ok.
