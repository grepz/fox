-module(fox_SUITE).

%% test needs connection to RabbitMQ

-include("fox.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").


-export([all/0,
         init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2,
         create_channel_test/1,
         subscribe_test/1, subscribe_state_test/1,
         consumer_down_test/1, channel_down_test/1
        ]).


-spec all() -> list().
all() ->
    [create_channel_test,
     subscribe_test,
     subscribe_state_test,
     consumer_down_test,
     channel_down_test
    ].


-spec init_per_suite(list()) -> list().
init_per_suite(Config) ->
    application:ensure_all_started(fox),
    Config.


-spec end_per_suite(list()) -> list().
end_per_suite(Config) ->
    application:stop(fox),
    Config.


-spec init_per_testcase(atom(), list()) -> list().
init_per_testcase(Test, Config) ->
    Params = #{host => "localhost",
               port => 5672,
               virtual_host => <<"/">>,
               username => <<"guest">>,
               password => <<"guest">>},
    ok = fox:create_connection_pool(Test, Params),
    Config.


-spec end_per_testcase(atom(), list()) -> list().
end_per_testcase(Test, Config) ->
    ok = fox:close_connection_pool(Test),
    Config.


-spec create_channel_test(list()) -> ok.
create_channel_test(_Config) ->
    {ok, Channel} = fox:create_channel(create_channel_test),
    ?assertEqual(ok, fox:declare_exchange(Channel, <<"my_exchange">>)),
    ?assertEqual(ok, fox:delete_exchange(Channel, <<"my_exchange">>)),
    amqp_channel:close(Channel),
    ok.


-spec subscribe_test(list()) -> ok.
subscribe_test(_Config) ->
    T = ets:new(subscribe_test_ets, [public, named_table]),
    SortF = fun(I1, I2) -> element(1, I1) < element(1, I2) end,

    {ok, SChannel} = fox:subscribe(subscribe_test, subscribe_test, "some args"),

    timer:sleep(200),
    Res1 = lists:sort(SortF, ets:tab2list(T)),
    ct:pal("Res1: ~p", [Res1]),
    ?assertMatch([{1, init, SChannel, "some args"}], Res1),

    {ok, PChannel} = fox:create_channel(subscribe_test),
    fox:publish(PChannel, <<"my_exchange">>, <<"my_key">>, <<"Hi there!">>),
    timer:sleep(200),
    Res2 = lists:sort(SortF, ets:tab2list(T)),
    ct:pal("Res2: ~p", [Res2]),
    ?assertMatch([
                  {1, init, SChannel, "some args"},
                  {2, handle_basic_deliver, SChannel, <<"Hi there!">>}
                 ],
                 Res2),

    fox:publish(PChannel, <<"my_exchange">>, <<"my_key">>, <<"Hello!">>),
    timer:sleep(200),
    Res3 = lists:sort(SortF, ets:tab2list(T)),
    ct:pal("Res3: ~p", [Res3]),
    ?assertMatch([
                  {1, init, SChannel, "some args"},
                  {2, handle_basic_deliver, SChannel, <<"Hi there!">>},
                  {3, handle_basic_deliver, SChannel, <<"Hello!">>}
                 ],
                 Res3),

    fox:unsubscribe(subscribe_test, SChannel),
    timer:sleep(200),
    Res4 = lists:sort(SortF, ets:tab2list(T)),
    ct:pal("Res4: ~p", [Res4]),
    ?assertMatch([
                  {1, init, SChannel, "some args"},
                  {2, handle_basic_deliver, SChannel, <<"Hi there!">>},
                  {3, handle_basic_deliver, SChannel, <<"Hello!">>},
                  {4, terminate, SChannel}
                 ],
                 Res4),

    amqp_channel:close(PChannel),
    ets:delete(T),
    ok.


-spec subscribe_state_test(list()) -> ok.
subscribe_state_test(_Config) ->
    {ok, ChannelPid} = fox:subscribe(subscribe_state_test, sample_channel_consumer),
    ?assert(erlang:is_process_alive(ChannelPid)),

    ConnectionWorkerPid = get_connection_worker(subscribe_state_test),
    State = sys:get_state(ConnectionWorkerPid),
    ct:pal("State: ~p", [State]),
    {state, _, _, _, Consumers, _, TID} = State,

    EtsData = lists:sort(ets:tab2list(TID)),
    ct:pal("EtsData: ~p", [EtsData]),
    ?assertMatch([{ChannelPid, {consumer, _, _}, {channel, ChannelPid, _}},
                  {_, {consumer, _, _}, {channel, ChannelPid, _}}
                 ],
                 EtsData),


    [{ChannelPid, {consumer, ConsumerPid, _}, _}] = ets:lookup(TID, ChannelPid),
    ?assertEqual({ok, {ConsumerPid, sample_channel_consumer, []}}, maps:find(ChannelPid, Consumers)),

    %% Unsubscribe
    fox:unsubscribe(subscribe_state_test, ChannelPid),

    timer:sleep(200),
    ?assert(not erlang:is_process_alive(ChannelPid)),

    State2 = sys:get_state(ConnectionWorkerPid),
    {state, _, _, _, Consumers2, _, TID} = State2,

    ?assertEqual(error, maps:find(ChannelPid, Consumers2)),
    ?assertEqual([], ets:tab2list(TID)),
    ok.


-spec consumer_down_test(list()) -> ok.
consumer_down_test(_Config) ->
    T = ets:new(subscribe_test_ets, [public, named_table]),
    SortF = fun(I1, I2) -> element(1, I1) < element(1, I2) end,

    {ok, ChannelPid} = fox:subscribe(consumer_down_test, subscribe_test, "args2"),
    timer:sleep(200),
    Res1 = lists:sort(SortF, ets:tab2list(T)),
    ?assertMatch([{1, init, ChannelPid, "args2"}], Res1),

    {ok, PChannel} = fox:create_channel(consumer_down_test),
    fox:publish(PChannel, <<"my_exchange">>, <<"my_key">>, <<"Hi there!">>),
    timer:sleep(200),
    Res2 = lists:sort(SortF, ets:tab2list(T)),
    ct:pal("Res2: ~p", [Res2]),
    ?assertMatch([
                  {1, init, ChannelPid, "args2"},
                  {2, handle_basic_deliver, ChannelPid, <<"Hi there!">>}
                 ],
                 Res2),


    ConnectionWorkerPid = get_connection_worker(consumer_down_test),
    State = sys:get_state(ConnectionWorkerPid),
    ct:pal("State: ~p", [State]),
    {state, _, _, _, Consumers, _, TID} = State,

    EtsData = lists:sort(ets:tab2list(TID)),
    [{ChannelPid, {consumer, ConsumerPid, _}, _}] = ets:lookup(TID, ChannelPid),

    ?assertMatch([
                  {ChannelPid, {consumer, ConsumerPid, _}, {channel, ChannelPid, _}},
                  {ConsumerPid, {consumer, ConsumerPid, _}, {channel, ChannelPid, _}}
                 ],
                 EtsData),
    ?assertEqual({ok, {ConsumerPid, subscribe_test, "args2"}}, maps:find(ChannelPid, Consumers)),

    fox_channel_consumer:stop(ConsumerPid),
    timer:sleep(200),

    State2 = sys:get_state(ConnectionWorkerPid),
    {state, _, _, _, Consumers2, _, TID} = State2,
    {ok, {ConsumerPid2, subscribe_test, "args2"}} = maps:find(ChannelPid, Consumers2),
    ?assertNotEqual(ConsumerPid, ConsumerPid2),
    ?assert(not erlang:is_process_alive(ConsumerPid)),
    ?assert(erlang:is_process_alive(ConsumerPid2)),

    EtsData2 = lists:sort(ets:tab2list(TID)),
    ?assertMatch([
                  {ChannelPid, {consumer, ConsumerPid2, _}, {channel, ChannelPid, _}},
                  {ConsumerPid2, {consumer, ConsumerPid2, _}, {channel, ChannelPid, _}}
                 ],
                 EtsData2),


    %% callback is still working
    Res3 = lists:sort(SortF, ets:tab2list(T)),
    ct:pal("Res3: ~p", [Res3]),
    ?assertMatch([
                  {1, init, ChannelPid, "args2"},
                  {2, handle_basic_deliver, ChannelPid, <<"Hi there!">>},
                  {3, terminate, ChannelPid},
                  {4, init, ChannelPid, "args2"}
                 ],
                 Res3),

    fox:publish(PChannel, <<"my_exchange">>, <<"my_key">>, <<"alloha">>),
    timer:sleep(200),
    Res4 = lists:sort(SortF, ets:tab2list(T)),
    ct:pal("Res4: ~p", [Res4]),
    ?assertMatch([
                  {1, init, ChannelPid, "args2"},
                  {2, handle_basic_deliver, ChannelPid, <<"Hi there!">>},
                  {3, terminate, ChannelPid},
                  {4, init, ChannelPid, "args2"},
                  {5, handle_basic_deliver, ChannelPid, <<"alloha">>}
                 ],
                 Res4),

    %% unsubscribe
    fox:unsubscribe(consumer_down_test, ChannelPid),
    timer:sleep(200),
    ?assert(not erlang:is_process_alive(ChannelPid)),

    State3 = sys:get_state(ConnectionWorkerPid),
    {state, _, _, _, Consumers3, _, TID} = State3,

    ?assertEqual(error, maps:find(ChannelPid, Consumers3)),
    ?assertEqual([], ets:tab2list(TID)),

    Res5 = lists:sort(SortF, ets:tab2list(T)),
    ct:pal("Res5: ~p", [Res5]),
    ?assertMatch([
                  {1, init, ChannelPid, "args2"},
                  {2, handle_basic_deliver, ChannelPid, <<"Hi there!">>},
                  {3, terminate, ChannelPid},
                  {4, init, ChannelPid, "args2"},
                  {5, handle_basic_deliver, ChannelPid, <<"alloha">>},
                  {6, terminate, ChannelPid}
                 ],
                 Res5),

    amqp_channel:close(PChannel),
    ets:delete(T),
    ok.


-spec channel_down_test(list()) -> ok.
channel_down_test(_Config) ->
    %% amqp_channel:close(ChannelPid),

    %% - удаляется consumer pid из ets и consumer, channel pid в ets остается
    %% - вызов unsubscribe после этого работает нормально
    ok.


-spec get_connection_worker(atom()) -> pid().
get_connection_worker(PoolName) ->
    ConnectionSups = supervisor:which_children(fox_connection_pool_sup),
    ConnectionSupPid = lists:foldl(fun({{fox_connection_sup, PName}, SupPid, _, _}, Acc) ->
                                           case PName of
                                               PoolName -> SupPid;
                                               _ -> Acc
                                           end
                                   end, undefined, ConnectionSups),
    ConnectionWorkers = supervisor:which_children(ConnectionSupPid),
    {_, ConnectionWorkerPid, _, _} = hd(lists:reverse(ConnectionWorkers)),
    ConnectionWorkerPid.