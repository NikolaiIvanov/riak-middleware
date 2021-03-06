-module(copy_handler).
-behavior(cowboy_handler).

-export([init/2, content_types_provided/2, content_types_accepted/2,
	 to_json/2, allowed_methods/2, forbidden/2, error_response/2,
	 resource_exists/2, previously_existed/2, validate_post/5,
	 handle_post/2, do_conditional_copy/5]).

-include("riak.hrl").
-include("action_log.hrl").

init(Req, Opts) ->
    {cowboy_rest, Req, Opts}.

%%
%% Returns callback 'handle_post()'
%% ( called after 'resource_exists()' )
%%
content_types_accepted(Req, State) ->
    {[{{<<"application">>, <<"json">>, '*'}, handle_post}], Req, State}.

%%
%% Returns callback 'to_json()'
%% ( called after 'forbidden()' )
%%
content_types_provided(Req, State) ->
    {[
	{{<<"application">>, <<"json">>, []}, to_json}
    ], Req, State}.

error_response(Req0, ErrorCode) ->
    Req1 = cowboy_req:set_resp_body(jsx:encode([{error, ErrorCode}]), Req0),
    {true, Req1, []}.

validate_post(Req, UserName, TenantName, SrcBucketName, FieldValues) ->
    SrcPrefix = proplists:get_value(<<"src_prefix">>, FieldValues),
    DstBucketName0 =
	case proplists:get_value(<<"dst_bucket_name">>, FieldValues) of
	    undefined -> undefined;
	    DstBucketName1 ->
		binary_to_list(unicode:characters_to_binary(DstBucketName1))
	end,
    DstPrefix = proplists:get_value(<<"dst_prefix">>, FieldValues),
    SrcObjectNames0 = proplists:get_value(<<"src_object_names">>, FieldValues),
    case (utils:is_valid_bucket_name(DstBucketName0, TenantName)
	    andalso utils:is_bucket_belongs_to_user(DstBucketName0, UserName, TenantName)
	    andalso erlang:is_list(SrcObjectNames0)) of
	true ->
	    case (utils:is_valid_hex_prefix(SrcPrefix)
		    andalso utils:is_valid_hex_prefix(DstPrefix)) of
		true ->
		    SrcObjectNames1 = [binary_to_list(unicode:characters_to_binary(N)) || N <- SrcObjectNames0],
		    [
			{src_bucket_name, SrcBucketName},
			{src_prefix, SrcPrefix},
			{src_object_names, SrcObjectNames1},
			{dst_bucket_name, DstBucketName0},
			{dst_prefix, DstPrefix}
		    ];
		false ->
		    error_response(Req, 11)
	    end;
	false ->
	    error_response(Req, 7)
    end.

%%
%% Validates provided content range values and calls 'upload_to_riak()'
%%
handle_post(Req0, State0) ->
    case cowboy_req:method(Req0) of
	<<"POST">> ->
	    {ok, Body, Req1} = cowboy_req:read_body(Req0),
	    UserName = proplists:get_value(user_name, State0),
	    TenantName = proplists:get_value(tenant_name, State0),
	    FieldValues = jsx:decode(Body),
	    SrcBucketName = proplists:get_value(src_bucket_name, State0),
	    case validate_post(Req1, UserName, TenantName, SrcBucketName, FieldValues) of
		{true, Req3, []} ->
		    {true, Req3, []};  % error
		State1 ->
		    State2 = State1 ++ State0,
		    copy(Req1, State2)
	    end;
	_ ->
	    error_response(Req0, 2)
    end.

%%
%% Removes part of prefix from source file.
%% Returns object name that do not yet exist in destination pseudo-directory
%%
shorten_prefix(BucketName, ObjectName0, SrcPrefix0, DstPrefix) ->
    ObjectName1 =
	case SrcPrefix0 of
	    undefined -> ObjectName0;
	    SrcPrefix1 ->
		re:replace(ObjectName0, "^" ++ SrcPrefix1, "", [{return, list}])
    end,
    ObjectName2 = riak_api:pick_object_name(BucketName, DstPrefix, list_to_binary(ObjectName1)),
    utils:prefixed_object_name(DstPrefix, ObjectName2).

-spec do_conditional_copy(string(), string(), string(), string(), string()) -> list().

do_conditional_copy(SrcBucketName, DstBucketName, ObjectName, SrcPrefix, DstPrefix) ->
    %% short prefix is used to update index ( html list of objects )
    ShortPrefix0 = shorten_prefix(DstBucketName, ObjectName, SrcPrefix, DstPrefix),
    case utils:is_hidden_object([{key, ObjectName}]) of
	true ->
	    case lists:suffix(?RIAK_INDEX_FILENAME, ObjectName) of
		true ->
		    %% unicode prefix is effective path of Pseudo Directory
		    UnicodePrefix0 = utils:unhex_path(ObjectName),
		    UnicodePrefix1 = string:sub_string(UnicodePrefix0, 1,
			length(UnicodePrefix0) - length(?RIAK_INDEX_FILENAME)),
		    ShortPrefix1 = filename:dirname(ShortPrefix0)++"/",
		    riak_api:update_index(DstBucketName, ShortPrefix1, utils:unhex_path(ShortPrefix1)),
		    Result = case SrcPrefix of
			undefined ->
			    ["/"] ++ UnicodePrefix1;
			_ ->
			    UnicodePrefix1
		    end,
		    Result;
		false ->
		    %% just ignore other special files
		    undefined
		end;
	false ->
	    %% TODO: check if user has access to DST bucket
	    %%       add error handling in case some objects were not copied
	    %%       restrict READ access
	    CopyResult = riak_api:copy_object(DstBucketName, ShortPrefix0, SrcBucketName, ObjectName,
		[{acl, public_read}]),
	    case proplists:get_value(content_length, CopyResult, 0) of
		0 -> undefined;
		_ ->
		    UnicodePrefix0 = utils:unhex_path(ObjectName),
		    ShortPrefix1 = filename:dirname(ShortPrefix0)++"/",
		    riak_api:update_index(DstBucketName, ShortPrefix1, UnicodePrefix0),
		    UnicodePrefix0
	    end
    end.

copy(Req0, State) ->
    UserName = proplists:get_value(user_name, State),
    TenantName = proplists:get_value(tenant_name, State),
    SrcBucketName = proplists:get_value(src_bucket_name, State),
    SrcPrefix0 =
	case proplists:get_value(src_prefix, State) of
	    undefined -> undefined;
	    SrcPrefix1 ->
		binary_to_list(SrcPrefix1)
	end,
    SrcObjectNames = proplists:get_value(src_object_names, State),
    DstBucketName = proplists:get_value(dst_bucket_name, State),
    DstPrefix0 =
	case proplists:get_value(dst_prefix, State) of
	    undefined -> undefined;
	    DstPrefix1 -> binary_to_list(DstPrefix1)
	end,
    ObjectNamesToCopy0 = [
     case string:sub_string(N, length(N), length(N)) =:= "/" of
	true -> riak_api:recursively_list_pseudo_dir(SrcBucketName, N);
	false -> [N]
     end || N <- SrcObjectNames],
    ObjectNamesToCopy1 = lists:foldl(fun(X, Acc) -> X ++ Acc end, [], ObjectNamesToCopy0),

    CopiedObjectNames0 = [do_conditional_copy(SrcBucketName, DstBucketName, ObjectName, SrcPrefix0, DstPrefix0) ||
	ObjectName <- ObjectNamesToCopy1],
    CopiedObjectNames1 = [O || O <- CopiedObjectNames0, O =/= undefined],

    ActionLogRecord0 = #riak_action_log_record{
	action="copy",
	user_name=UserName,
	tenant_name=TenantName,
	timestamp=io_lib:format("~p", [utils:timestamp()])
	},

    ReadableList0 = lists:flatten(utils:join_list_with_separator(CopiedObjectNames1, ", ", [])),

    Summary0 = lists:flatten([["Copied from: "], [ReadableList0]]),
    ActionLogRecord1 = ActionLogRecord0#riak_action_log_record{details=Summary0},
    action_log:add_record(DstBucketName, DstPrefix0, ActionLogRecord1),

    case SrcPrefix0 of
	undefined -> ok;
	_ ->
	    ReadableList1 = lists:flatten(["/"]++utils:join_list_with_separator(
		[DstBucketName, utils:unhex_path(DstPrefix0)], "/", [])),
	    Summary1 = lists:flatten([["Copied "], [ReadableList0], [" to: "], [ReadableList1]]),

	    ActionLogRecord2 = ActionLogRecord0#riak_action_log_record{details=Summary1},
	    action_log:add_record(SrcBucketName, SrcPrefix0, ActionLogRecord2)
    end,
    {true, Req0, []}.

%%
%% Serializes response to json
%%
to_json(Req0, State) ->
    {"{\"status\": \"ok\"}", Req0, State}.

%%
%% Called first
%%
allowed_methods(Req, State) ->
    {[<<"POST">>], Req, State}.

%%
%% Checks if provided token is correct.
%% ( called after 'allowed_methods()' )
%%
%%
forbidden(Req0, _State) ->
    Token = case cowboy_req:binding(token, Req0) of
	undefined -> undefined;
	TokenValue -> binary_to_list(TokenValue)
    end,
    case keystone_api:check_token(Token) of
	not_found ->
	    {true, Req0, []};
	Ids ->
	    {false, Req0, Ids}
    end.

%%
%% Validates request parameters
%% ( called after 'content_types_provided()' )
%%
resource_exists(Req0, State) ->
    SrcBucketName = binary_to_list(cowboy_req:binding(src_bucket_name, Req0)),
    TenantName = proplists:get_value(tenant_name, State),

    case (utils:is_bucket_belongs_to_tenant(SrcBucketName, TenantName)
	    andalso utils:is_valid_bucket_name(SrcBucketName, TenantName)) of
	true ->
	    {true, Req0, State ++ [{src_bucket_name, SrcBucketName}]};
	false ->
	    {false, Req0, []}
    end.

previously_existed(Req0, _State) ->
    {false, Req0, []}.
