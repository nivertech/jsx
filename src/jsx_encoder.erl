%% The MIT License

%% Copyright (c) 2010 Alisdair Sullivan <alisdairsullivan@yahoo.ca>

%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:

%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.

%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%% THE SOFTWARE.


-module(jsx_encoder).
-author("alisdairsullivan@yahoo.ca").

-export([term_to_json/2]).

-include("./include/jsx_types.hrl").



-spec term_to_json(JSON::json(), Opts::encoder_opts()) -> binary().

term_to_json(List, Opts) ->
    case proplists:get_value(strict, Opts, true) of
        true when is_list(List) -> continue
        ; false -> continue
        ; true -> erlang:error(badarg)
    end,
    Encoding = proplists:get_value(encoding, Opts, utf8),
    json:format(event_generator(term_to_events(List)), [{output_encoding, Encoding}] ++ Opts).
    
event_generator([]) ->
    fun() -> {event, end_json, fun() -> {incomplete, fun(end_stream) -> ok end} end} end;    
event_generator([Next|Rest]) ->
    fun() -> {event, Next, event_generator(Rest)} end.
    
 
term_to_events([{}]) ->
    [start_object, end_object];
term_to_events([First|_] = List) when is_tuple(First) ->
    proplist_to_events(List, [start_object]);
term_to_events(List) when is_list(List) ->
    list_to_events(List, [start_array]);
term_to_events(Term) ->
    term_to_event(Term). 
       
    
proplist_to_events([{Key, Term}|Rest], Acc) ->
    Event = term_to_event(Term),
    EncodedKey = key_to_event(Key),
    case key_repeats(EncodedKey, Acc) of
        false -> proplist_to_events(Rest, Event ++ EncodedKey ++ Acc)
        ; true -> erlang:error(badarg)
    end;
proplist_to_events([], Acc) ->
    lists:reverse([end_object] ++ Acc);
proplist_to_events(_, _) ->
    erlang:throw(badarg).
    
    
list_to_events([Term|Rest], Acc) ->
    list_to_events(Rest, term_to_event(Term) ++ Acc);
list_to_events([], Acc) ->
    lists:reverse([end_array] ++ Acc).


term_to_event(List) when is_list(List) ->
    term_to_events(List);
term_to_event(Float) when is_float(Float) ->
    [{float, float_to_decimal(Float)}];
term_to_event(Integer) when is_integer(Integer) ->
    [{integer, erlang:integer_to_list(Integer)}];
term_to_event(String) when is_binary(String) -> 
    [{string, String}];
term_to_event(true) -> [{literal, true}];
term_to_event(false) -> [{literal, false}];
term_to_event(null) -> [{literal, null}];
term_to_event(_) -> erlang:error(badarg).


key_to_event(Key) when is_atom(Key) ->
    [{key, erlang:atom_to_list(Key)}];
key_to_event(Key) when is_binary(Key) ->
    [{key, unicode:characters_to_list(Key, utf8)}].
    

key_repeats([Key], [Key|_]) -> true;
key_repeats(Key, [_|Rest]) -> key_repeats(Key, Rest);
key_repeats(_, []) -> false.


%% conversion of floats to 'nice' decimal output. erlang's float implementation is almost
%%   but not quite ieee 754. it converts negative zero to plain zero silently, and throws
%%   exceptions for any operations that would produce NaN or infinity. as far as I can
%%   tell that is. trying to match against NaN or infinity binary patterns produces nomatch 
%%   exceptions, and arithmetic operations produce badarg exceptions. with that in mind, this 
%%   function makes no attempt to handle special values (except for zero)

%% algorithm from "Printing FLoating-Point Numbers Quickly and Accurately" by Burger & Dybvig
float_to_decimal(0.0) -> "0.0";
float_to_decimal(Num) when is_float(Num) ->
    {F, E} = extract(<<Num:64/float>>),
    {R, S, MP, MM} = initial_vals(F, E),
    K = ceiling(math:log10(abs(Num)) - 1.0e-10),
    Round = F band 1 =:= 1,
    {Dpoint, Digits} = scale(R, S, MP, MM, K, Round),
    if Num >= 0 -> format(Dpoint, Digits)
        ; Num < 0 -> "-" ++ format(Dpoint, Digits)
    end.


extract(<<_:1, 0:11, Frac:52>>) -> {Frac, -1074};
extract(<<_:1, Exp:11, Frac:52>>) -> {Frac + (1 bsl 52), Exp - 1075}.


ceiling(X) ->
    Y = trunc(X),
    case X - Y of 
        Z when Z > 0 -> Y + 1 
        ; _ -> Y 
    end.
    

initial_vals(F, E) when E >= 0, F /= 1 bsl 52 ->
    BE = 1 bsl E,
    {F * BE * 2, 2, BE, BE};    
initial_vals(F, E) when E >= 0 ->
    BE = 1 bsl E,
    {F * BE * 4, 4, BE * 2, BE};
initial_vals(F, E) when E == -1074; F /= 1 bsl 52 ->
    {F * 2, 1 bsl (-E + 1), 1, 1};
initial_vals(F, E) ->
    {F * 4, 1 bsl (-E + 2), 2, 1}.
    
    
scale(R, S, MP, MM, K, Round) ->
    case K >= 0 of
        true -> fixup(R, S * pow(10, K), MP, MM, K, Round)
        ; false -> 
            Scale = pow(10, -1 * K),
            fixup(R * Scale, S, MP * Scale, MM * Scale, K, Round)
    end.
    
    
fixup(R, S, MP, MM, K, true) ->
    case (R + MP >= S) of
        true -> {K + 1, generate(R, S, MP, MM, true)}
        ; false -> {K, generate(R * 10, S, MP * 10, MM * 10, true)}
    end;
fixup(R, S, MP, MM, K, false) ->
    case (R + MP > S) of
        true -> {K + 1, generate(R, S, MP, MM, true)}
        ; false -> {K, generate(R * 10, S, MP * 10, MM * 10, true)}
    end.
    

generate(RT, S, MP, MM, Round) ->
    D = RT div S,
    R = RT rem S,
    TC1 = case Round of true -> (R =< MM); false -> (R < MM) end,
    TC2 = case Round of true -> (R + MP >= S); false -> (R + MP > S) end,
    case TC1 of
        false -> case TC2 of 
                false -> [D | generate(R * 10, S, MP * 10, MM * 10, Round)]
                ; true -> [D + 1]
            end
        ; true -> case TC2 of
                false -> [D]
                ; true -> case R * 2 < S of
                    true -> [D]
                    ; false -> [D + 1]
                end
            end
    end.
    

%% this is not efficient at all and should be replaced with a lookup table probably
pow(_B, 0) -> 1;
pow(B, E) when E > 0 -> pow(B, E, 1).
    
pow(B, E, Acc) when E < 2 -> B * Acc;
pow(B, E, Acc) when E band 1 == 1 -> pow(B * B, E bsr 1, B * Acc);
pow(B, E, Acc) -> pow(B * B, E bsr 1, Acc).
    
    
format(Dpoint, Digits) when Dpoint =< length(Digits), Dpoint > 0 ->
    format(Digits, Dpoint, []);
format(Dpoint, Digits) when Dpoint > 0 ->
    Pad = Dpoint - length(Digits),
    case Pad of
        X when X > 6 -> format(Digits, 1, []) ++ "e" ++ integer_to_list(Dpoint - 1)
        ; _ -> format(Digits ++ [ 0 || _ <- lists:seq(1, Pad)], Dpoint, [])
    end;
format(Dpoint, Digits) when Dpoint < 0 ->
    format(Digits, 1, []) ++ "e" ++ integer_to_list(Dpoint - 1).
    

format([], 0, Acc) ->
    lists:reverse("0." ++ Acc);
format([], ignore, Acc) ->
    lists:reverse(Acc);
format(Digits, 0, Acc) ->
    format(Digits, ignore, "." ++ Acc); 
format([Digit|Digits], Dpoint, Acc) ->
    format(Digits, case Dpoint of ignore -> ignore; X -> X - 1 end, to_ascii(Digit) ++ Acc).

    
to_ascii(X) -> [X + 48].    %% ascii "1" is [49], "2" is [50], etc...