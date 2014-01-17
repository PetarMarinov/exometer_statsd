%% -------------------------------------------------------------------
%%
%% Copyright (c) 2013 Basho Technologies, Inc.  All Rights Reserved.
%%
%%   This Source Code Form is subject to the terms of the Mozilla Public
%%   License, v. 2.0. If a copy of the MPL was not distributed with this
%%   file, You can obtain one at http://mozilla.org/MPL/2.0/.
%%
%% -------------------------------------------------------------------

%% @doc Exometer histogram probe behavior
-module(exometer_histogram).
-behaviour(exometer_entry).

%% exometer_entry callbacks
-export([new/3,
         delete/3,
         get_value/4,
         get_datapoints/3,
         update/4,
         reset/3,
         sample/3,
         setopts/4]).

%% exometer_proc callback
-export([init/3]).

-export([average_sample/3,
         average_transform/2]).

-compile(inline).

-compile({parse_transform, exometer_igor}).
-compile({igor, [{files, ["src/exometer_util.erl"
                          , "src/exometer_proc.erl"
                          , "src/exometer_slot_slide.erl"
                          , "src/exometer_slide.erl"
                         ]}]}).

-include("exometer.hrl").

-record(st, {name,
             slide = undefined, %%
             slot_period = 1000, %% msec
             time_span = 60000, %% msec
             percentiles = [ 99.0 ], %% Which percentages to calculate
             truncate = true,
             histogram_module = exometer_slot_slide,
             opts = []}).

-define(DATAPOINTS,
        [n, mean, min, max, median, 50, 75, 90, 95, 99, 999 ]).


init(Name, Type, Options) ->
    {ok, St} = init_int(Name, Type, Options),
    process_flag(min_heap_size, 40000),
    loop(St).

loop(St) ->
    receive Msg ->
            loop(handle_msg(Msg, St))
    end.

handle_msg(Msg, St) ->
    case Msg of
        {exometer_proc, {update, Val}} ->
            update_int(Val, St);
        {exometer_proc, {update, Val, TS}} ->
            update_int(Val, TS, St);
        {exometer_proc, sample} ->
            %% ignore
            St;
        {exometer_proc, {From,Ref}, {get_value, DPs}} ->
            From ! {Ref, get_value_int(St, DPs)},
            St;
        {exometer_proc, {From,Ref}, {setopts, _Opts}} ->
            From ! {Ref, {error, unsupported}},
            St;
        {exometer_proc, reset} ->
            reset_int(St);
        {exometer_proc, stop} ->
            exometer_proc:stop();
        {exometer_proc, {From, Ref}, get_state} ->
            From ! {Ref, St},
            St;
        _ ->
            St
    end.


%%
%% exometer_entry callbacks
%%
new(Name, Type, Options) ->
    {ok, exometer_proc:spawn_process(Name, fun() ->
                                                   init(Name, Type, Options)
                                           end)}.

delete(_Name, _Type, Pid) ->
    exometer_proc:cast(Pid, stop).

get_value(_Name, _Type, Pid, DataPoints) ->
    exometer_proc:call(Pid, {get_value, DataPoints}).

%% No need to go through the process for this one.
get_datapoints(_Name, _Type, _Ref) ->
    ?DATAPOINTS.


init_int(Name, _Type, Options) ->
    St = process_opts(#st{name = Name}, [{histogram_module, exometer_slot_slide},
                                         {time_span, 60000},
                                         {slot_period, 10}] ++ Options),

    Slide = (St#st.histogram_module):new(St#st.time_span,
                                         St#st.slot_period,
                                         fun average_sample/3,
                                         fun average_transform/2,
                                         Options),
    {ok, St#st{slide = Slide}}.

get_value_int(St, default) ->
    get_value_int_(St, ?DATAPOINTS);
get_value_int(_, []) ->
    [];
get_value_int(St, DataPoints) ->
    get_value_int_(St, DataPoints).

get_value_int_(#st{truncate = Trunc,
                   histogram_module = Module} = St, DataPoints) ->
    %% We need element count and sum of all elements to get mean value.
    Tot0 = case Trunc of true -> 0; false -> 0.0 end,
    {Length, Total, Min0, Max, Lst0, Xtra} =
        Module:foldl(
          fun
              ({_TS, {Val, NMin, NMax, X}},
               {Length, Total, OMin, OMax, List, Xs}) ->
                  {Length + 1, Total + Val, min(OMin, NMin), max(OMax, NMax),
                   [Val|List], [X|Xs]};

              ({_TS, Val}, {Length, Total, Min, Max, List, Xs}) ->
                  {Length + 1, Total + Val, min(Val, Min), max(Val, Max),
                   [Val|List], Xs}
          end,
          {0,  Tot0, infinity, 0, [], []}, St#st.slide),
    Min = if Min0 == infinity -> 0; true -> Min0 end,
    Mean = case Length of
               0 -> 0.0;
               N -> Total / N
           end,

    {Len, List} =
        if Module == exometer_slot_slide ->
                {Length1, Lst} = add_extra(Length, Lst0, Xtra),
                {Length1 + 2, [Min|lists:sort(Lst)] ++ [Max]};
           true ->
                {Length, lists:sort(Lst0)}
        end,
    Results = exometer_util:get_statistics2(Len, List, Mean),
    [get_dp(K, Results, Trunc) || K <- DataPoints].

add_extra(Length, L, []) ->
    {Length, L};
add_extra(Length, L, X) when Length < 300 ->
    %% aim for 600 elements, since experiments indicate that this
    %% gives decent accuracy at decent speed (ca 300-400 us on a Core i7)
    Pick = max(2, ((600 - Length) div Length) + 1),
    pick_extra(X, Pick, Pick, L, Length);
add_extra(Length, L, X) ->
    %% Always take something from the Xtra, since this improves percentile
    %% accuracy
    pick_extra(X, 1, 1, L, Length).


pick_extra([[H|T]|T1], P, Pick, L, Length) when P > 0 ->
    pick_extra([T|T1], P-1, Pick, [H|L], Length+1);
pick_extra([_|T], 0, Pick, L, Length) ->
    pick_extra(T, Pick, Pick, L, Length);
pick_extra([[]|T], _, Pick, L, Length) ->
    pick_extra(T, Pick, Pick, L, Length);
pick_extra([], _, _, L, Length) ->
    {Length, L}.

get_dp(K, L, Trunc) ->
    case lists:keyfind(K, 1, L) of
        false ->
            {K, if Trunc -> 0; true -> 0.0 end};
        {median, F} when is_float(F) ->
            %% always truncate median
            {median, trunc(F)};
        {_, V} = DP when is_integer(V) ->
            DP;
        {_,_} = DP ->
            opt_trunc(Trunc, DP)
    end.

perc(P, Len) when P > 1.0 ->
    round((P / 10) * Len);

perc(P, Len) ->
    round(P * Len).

setopts(_Name, _Opts, _Type, _Ref)  ->
    {error, unsupported}.

update(_Name, Value, _Type, Pid) ->
    exometer_proc:cast(Pid, {update, Value, exometer_util:timestamp()}).

update_int(Value, #st{slide = Slide,
                      histogram_module = Module} = St) ->
    St#st{slide = Module:add_element(Value, Slide)}.

update_int(Value, TS, #st{slide = Slide,
                      histogram_module = Module} = St) ->
    St#st{slide = Module:add_element(TS, Value, Slide)}.


reset(_Name, _Type, Pid) ->
    exometer_proc:cast(Pid, reset).

reset_int(#st{slide = Slide,
              histogram_module = Module} = St) ->
    St#st{slide = Module:reset(Slide)}.

sample(_Name, _Type, _Ref) ->
    {error, unsupported}.

process_opts(St, Options) ->
    exometer_proc:process_options(Options),
    lists:foldl(
      fun
          %% Sample interval.
          ( {time_span, Val}, St1) -> St1#st {time_span = Val};
          ( {slot_period, Val}, St1) -> St1#st {slot_period = Val};
          ( {percentiles, Val}, St1) -> St1#st {percentiles = Val};
          ( {histogram_module, Val}, St1) -> St1#st {histogram_module = Val};
          ( {truncate, Val}, St1) when is_boolean(Val) ->
              St1#st{truncate = Val};
          %% Unknown option, pass on to State options list, replacing
          %% any earlier versions of the same option.
          ({Opt, Val}, St1) ->
              St1#st{ opts = [ {Opt, Val}
                               | lists:keydelete(Opt, 1, St1#st.opts) ] }
      end, St, Options).

-record(sample, {count, total, min, max, extra = []}).
%% Simple sample processor that maintains an average
%% of all sampled values
average_sample(_TS, Val, undefined) ->
    #sample{count = 1,
            total = Val,
            min = Val,
            max = Val};

average_sample(_TS, Val, #sample{count = Count,
                                 total = Total,
                                 min = Min,
                                 max = Max, extra = X} = S) ->
    Count1 = Count + 1,
    X1 = if Count1 rem 4 == 0 -> [Val|X];
            true -> X
         end,
    S#sample{count = Count1,
             total = Total + Val,
             min = min(Min, Val),
             max = max(Max, Val),
             extra = X1}.

%% If average_sample() has not been called for the current time slot,
%% then the provided state will still be 'undefined'
average_transform(_TS, undefined) ->
    undefined;

%% Return the calculated total for the slot and return it as the
%% element to be stored in the histogram.
average_transform(_TS, #sample{count = Count,
                               total = Total,
                               min = Min,
                               max = Max, extra = X}) ->
    %% Return the sum of all counter increments received during this slot
    {Total / Count, Min, Max, X}.

nth(_, []) ->
    0;
nth(N, [_|_] = L) ->
    lists:nth(N, L).


opt_trunc(true, {K,V}) when is_float(V) ->
    {K, trunc(V)};
opt_trunc(_, V) ->
    V.

dbg(_) ->
    ok.
