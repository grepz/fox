-module(fox).

-export([validate_params_network/1,
         create_connection_pool/2,
         create_connection_pool/3,
         close_connection_pool/1,
         get_channel/1,
         subscribe/3, subscribe/4, unsubscribe/2,
         declare_exchange/2, declare_exchange/3,
         delete_exchange/2, delete_exchange/3,
         declare_queue/2, declare_queue/3,
         delete_queue/2, delete_queue/3,
         bind_queue/4, bind_queue/5,
         unbind_queue/4, unbind_queue/5,
         publish/4, publish/5,
         qos/2,
         test_run/0]).

-include("fox.hrl").


%%% module API

-spec validate_params_network(#amqp_params_network{} | map()) -> ok | {error, term()}.
validate_params_network(Params) when is_map(Params) ->
    validate_params_network(fox_utils:map_to_params_network(Params));

validate_params_network(Params) ->
    true = fox_utils:validate_params_network_types(Params),
    case amqp_connection:start(Params) of
        {ok, Connection} -> amqp_connection:close(Connection), ok;
        {error, Reason} -> {error, Reason}
    end.


-spec create_connection_pool(pool_name(), #amqp_params_network{} | map()) -> ok.
create_connection_pool(PoolName, Params) ->
    {ok, PoolSize} = application:get_env(fox, connection_pool_size),
    create_connection_pool(PoolName, Params, PoolSize).


-spec create_connection_pool(pool_name(), #amqp_params_network{} | map(), integer()) -> ok.
create_connection_pool(PoolName0, Params, PoolSize) ->
    ConnectionParams = fox_utils:map_to_params_network(Params),
    true = fox_utils:validate_params_network_types(ConnectionParams),
    error_logger:info_msg("fox create pool ~p ~s",
        [PoolName0, fox_utils:params_network_to_str(ConnectionParams)]),
    PoolName = fox_utils:name_to_atom(PoolName0),
    {ok, _} = fox_sup:start_pool(PoolName, ConnectionParams, PoolSize),
    ok.


-spec close_connection_pool(pool_name()) -> ok | {error, not_found}.
close_connection_pool(PoolName0) ->
    PoolName = fox_utils:name_to_atom(PoolName0),
    case fox_sup:pool_exists(PoolName) of
        true ->
            error_logger:info_msg("fox stop pool ~p", [PoolName0]),
            fox_conn_pool:stop(PoolName),
            fox_pub_pool:stop(PoolName),
            fox_sup:stop_pool(PoolName);
        false -> {error, not_found}
    end.


-spec get_channel(pool_name()) -> {ok, pid()} | {error, term()}.
get_channel(PoolName0) ->
    PoolName = fox_utils:name_to_atom(PoolName0),
    fox_pub_pool:get_channel(PoolName).


-spec subscribe(pool_name(), subscribe_queue(), module()) -> {ok, reference()} | {error, term()}.
subscribe(PoolName, Queue, SubsModule) ->
    subscribe(PoolName, Queue, SubsModule, []).


-spec subscribe(pool_name(), subscribe_queue(), module(), list()) -> {ok, reference()}.
subscribe(PoolName0, Queue, SubsModule, SubsArgs) ->
    PoolName = fox_utils:name_to_atom(PoolName0),

    Sub = #subscription{
        queue = Queue,
        subs_module = SubsModule,
        subs_args = SubsArgs
    },
    {ok, SPid} = fox_subs_sup:start_subscriber(PoolName, Sub),
    CPid = fox_conn_pool:get_conn_worker(PoolName),
    fox_conn_worker:register_subscriber(CPid, SPid),

    SubsMeta = #subs_meta{
        ref = make_ref(),
        conn_worker = CPid,
        subs_worker = SPid
    },
    fox_conn_pool:save_subs_meta(PoolName, SubsMeta),
    {ok, SubsMeta#subs_meta.ref}.


-spec unsubscribe(pool_name(), reference()) -> ok | {error, term()}.
unsubscribe(PoolName0, Ref) ->
    PoolName = fox_utils:name_to_atom(PoolName0),
    case fox_conn_pool:get_subs_meta(PoolName, Ref) of
        #subs_meta{conn_worker = CPid, subs_worker = SPid} ->
            fox_conn_worker:remove_subscriber(CPid, SPid),
            fox_conn_pool:remove_subs_meta(PoolName, Ref),
            fox_subs_worker:stop(SPid),
            ok;
        not_found -> {error, not_found}
    end.


-spec declare_exchange(pid(), binary()) -> ok | {error, term()}.
declare_exchange(ChannelPid, Name) when is_binary(Name) ->
    declare_exchange(ChannelPid, Name, maps:new()).


-spec declare_exchange(pid(), binary(), map()) -> ok | {error, term()}.
declare_exchange(ChannelPid, Name, Params) ->
    ExchangeDeclare = fox_utils:map_to_exchange_declare(Params),
    ExchangeDeclare2 = ExchangeDeclare#'exchange.declare'{exchange = Name},
    case fox_utils:channel_call(ChannelPid, ExchangeDeclare2) of
        #'exchange.declare_ok'{} -> ok;
        ok -> ok;
        {error, Reason} -> {error, Reason}
    end.

-spec delete_exchange(pid(), binary()) -> ok | {error, term()}.
delete_exchange(ChannelPid, Name) when is_binary(Name) ->
    delete_exchange(ChannelPid, Name, maps:new()).


-spec delete_exchange(pid(), binary(), map()) -> ok | {error, term()}.
delete_exchange(ChannelPid, Name, Params) ->
    ExchangeDelete = fox_utils:map_to_exchange_delete(Params),
    ExchangeDelete2 = ExchangeDelete#'exchange.delete'{exchange = Name},
    case fox_utils:channel_call(ChannelPid, ExchangeDelete2) of
        #'exchange.delete_ok'{} -> ok;
        {error, Reason} -> {error, Reason}
    end.


-spec declare_queue(pid(), binary()) -> ok | #'queue.declare_ok'{} | {error, term()}.
declare_queue(ChannelPid, Name) when is_binary(Name) ->
    declare_queue(ChannelPid, Name, maps:new()).


-spec declare_queue(pid(), binary(), map()) -> ok | #'queue.declare_ok'{} | {error, term()}.
declare_queue(ChannelPid, Name, Params) ->
    QueueDeclare = fox_utils:map_to_queue_declare(Params),
    QueueDeclare2 = QueueDeclare#'queue.declare'{queue = Name},
    case fox_utils:channel_call(ChannelPid, QueueDeclare2) of
        ok -> ok;
        #'queue.declare_ok'{} = Reply -> Reply;
        {error, Reason} -> {error, Reason}
    end.


-spec delete_queue(pid(), binary()) -> #'queue.delete_ok'{} | {error, term()}.
delete_queue(ChannelPid, Name) when is_binary(Name) ->
    delete_queue(ChannelPid, Name, maps:new()).


-spec delete_queue(pid(), binary(), map()) -> #'queue.delete_ok'{} | {error, term()}.
delete_queue(ChannelPid, Name, Params) ->
    QueueDelete = fox_utils:map_to_queue_delete(Params),
    QueueDelete2 = QueueDelete#'queue.delete'{queue = Name},
    case fox_utils:channel_call(ChannelPid, QueueDelete2) of
        ok -> ok;
        #'queue.delete_ok'{} = Reply -> Reply;
        {error, Reason} -> {error, Reason}
    end.


-spec bind_queue(pid(), binary(), binary(), binary()) -> ok | {error, term()}.
bind_queue(ChannelPid, Queue, Exchange, RoutingKey) ->
    bind_queue(ChannelPid, Queue, Exchange, RoutingKey, maps:new()).


-spec bind_queue(pid(), binary(), binary(), binary(), map()) -> ok | {error, term()}.
bind_queue(ChannelPid, Queue, Exchange, RoutingKey, Params) ->
    QueueBind = fox_utils:map_to_queue_bind(Params),
    QueueBind2 = QueueBind#'queue.bind'{queue = Queue,
                                        exchange = Exchange,
                                        routing_key = RoutingKey},
    case fox_utils:channel_call(ChannelPid, QueueBind2) of
        #'queue.bind_ok'{} -> ok;
        {error, Reason} -> {error, Reason}
    end.


-spec unbind_queue(pid(), binary(), binary(), binary()) -> ok | {error, term()}.
unbind_queue(ChannelPid, Queue, Exchange, RoutingKey) ->
    unbind_queue(ChannelPid, Queue, Exchange, RoutingKey, maps:new()).


-spec unbind_queue(pid(), binary(), binary(), binary(), map()) -> ok | {error, term()}.
unbind_queue(ChannelPid, Queue, Exchange, RoutingKey, Params) ->
    QueueUnbind = fox_utils:map_to_queue_unbind(Params),
    QueueUnbind2 = QueueUnbind#'queue.unbind'{queue = Queue,
                                              exchange = Exchange,
                                              routing_key = RoutingKey},
    case fox_utils:channel_call(ChannelPid, QueueUnbind2) of
        #'queue.unbind_ok'{} -> ok;
        {error, Reason} -> {error, Reason}
    end.


-spec publish(pool_name() | pid(), binary(), binary(), binary()) -> ok | {error, term()}.
publish(PoolOrChannel, Exchange, RoutingKey, Payload) ->
    publish(PoolOrChannel, Exchange, RoutingKey, Payload, maps:new()).


-spec publish(pool_name() | pid(), binary(), binary(), binary(), map()) -> ok | {error, term()}.
publish(PoolOrChannel, Exchange, RoutingKey, Payload, Params) when is_binary(Payload) ->
    Publish = fox_utils:map_to_basic_publish(
        Params#{exchange => Exchange, routing_key => RoutingKey}),
    PBasic = fox_utils:map_to_pbasic(Params),
    Message = #amqp_msg{payload = Payload, props = PBasic},

    PublishFun = case Params of
                     #{synchronous := true} -> channel_call;
                     _ -> channel_cast
                 end,
    if
        is_pid(PoolOrChannel) ->
            fox_utils:PublishFun(PoolOrChannel, Publish, Message),
            ok;
        true ->
            PoolName = fox_utils:name_to_atom(PoolOrChannel),
            case fox_pub_pool:get_channel(PoolName) of
                {ok, Channel} -> fox_utils:PublishFun(Channel, Publish, Message), ok;
                {error, Reason} -> {error, Reason}
            end
    end.


-spec qos(pool_name() | pid(), map()) -> ok | {error, term()}.
qos(PoolOrChannel, Params) ->
    QoS = fox_utils:map_to_basic_qos(Params),
    if
        is_pid(PoolOrChannel) ->
            #'basic.qos_ok'{} = amqp_channel:call(PoolOrChannel, QoS),
            ok;
        true ->
            PoolName = fox_utils:name_to_atom(PoolOrChannel),
            case fox_pub_pool:get_channel(PoolName) of
                {ok, Channel} -> #'basic.qos_ok'{} = amqp_channel:call(Channel, QoS), ok;
                {error, Reason} -> {error, Reason}
            end
    end.


-spec test_run() -> ok.
test_run() ->
    application:ensure_all_started(fox),

    Params = #{host => "localhost",
               port => 5672,
               virtual_host => <<"/">>,
               username => <<"guest">>,
               password => <<"guest">>},

    ok = validate_params_network(Params),
    {error, {auth_failure, _}} = validate_params_network(Params#{username => <<"Bob">>}),

    create_connection_pool("test_pool", Params),
    qos("test_pool", #{prefetch_count => 10}),
    Q1 = #'basic.consume'{queue = <<"q_tp">>},
    {ok, _Ref1} = subscribe("test_pool", Q1, sample_subs_callback, [<<"q_tp">>, <<"k_tp">>]),

    create_connection_pool("other_pool", Params),
    {ok, _Ref2} = subscribe("other_pool", <<"q_op_1">>, sample_subs_callback, [<<"q_op_1">>, <<"k_op_1">>]),
    {ok, _Ref3} = subscribe("other_pool", <<"q_op_2">>, sample_subs_callback, [<<"q_op_2">>, <<"k_op_2">>]),

    timer:sleep(500),

    {ok, PChannel} = get_channel("test_pool"),
    publish(PChannel, <<"my_exchange">>, <<"k_tp">>, <<"Hello 1">>),
    publish(PChannel, <<"my_exchange">>, <<"k_op_1">>, <<"Hello 2">>),
    publish("test_pool", <<"my_exchange">>, <<"k_op_2">>, <<"Hello 3">>),
    publish("other_pool", <<"my_exchange">>, <<"k_tp">>, <<"Hello 4">>),

    timer:sleep(2000),
    %% unsubscribe("test_pool", Ref1),

    %% timer:sleep(2000),
    %% unsubscribe("other_pool", Ref2),

    %% timer:sleep(2000),
    %% unsubscribe("other_pool", Ref3),

    close_connection_pool("other_pool"),

    ok.
