%% Originally taken from cowboy.
%%
%% Copyright (c) 2011-2017, Loïc Hoguin <essen@ninenines.eu>
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

%% Routing middleware.
%%
%% Resolve the handler to be used for the request based on the
%% routing information found in the <em>dispatch</em> environment value.
%% When found, the handler module and associated data are added to
%% the environment as the <em>handler</em> and <em>handler_opts</em> values
%% respectively.
%%
%% If the route cannot be found, processing stops with either
%% a 400 or a 404 reply.
-module(plug_chatterbox_router).

-export([compile/1]).
-export([execute/2]).

-type bindings() :: [{atom(), binary()}].
-type tokens() :: [binary()].
-export_type([bindings/0]).
-export_type([tokens/0]).

-type fields() :: any().
-type env() :: #{atom() => any()}.
-type req() :: #{'__struct__' => 'Elixir.Plug.Adapters.Chatterbox.Request', atom() => any()}.

-type route_match() :: '_' | iodata().
-type route_path() :: {Path::route_match(), Handler::module(), Opts::any()}
	| {Path::route_match(), fields(), Handler::module(), Opts::any()}.
-type route_rule() :: {Host::route_match(), Paths::[route_path()]}
	| {Host::route_match(), fields(), Paths::[route_path()]}.
-type routes() :: [route_rule()].
-export_type([routes/0]).

-type dispatch_match() :: '_' | <<_:8>> | [binary() | '_' | '...' | atom()].
-type dispatch_path() :: {dispatch_match(), fields(), module(), any()}.
-type dispatch_rule() :: {Host::dispatch_match(), fields(), Paths::[dispatch_path()]}.
-opaque dispatch_rules() :: [dispatch_rule()].
-export_type([dispatch_rules/0]).

-spec compile(routes()) -> dispatch_rules().
compile(Routes) ->
	compile(Routes, []).

compile([], Acc) ->
	lists:reverse(Acc);
compile([{Host, Paths}|Tail], Acc) ->
	compile([{Host, [], Paths}|Tail], Acc);
compile([{HostMatch, Fields, Paths}|Tail], Acc) ->
	HostRules = case HostMatch of
		'_' -> '_';
		_ -> compile_host(HostMatch)
	end,
	PathRules = compile_paths(Paths, []),
	Hosts = case HostRules of
		'_' -> [{'_', Fields, PathRules}];
		_ -> [{R, Fields, PathRules} || R <- HostRules]
	end,
	compile(Tail, Hosts ++ Acc).

compile_host(HostMatch) when is_list(HostMatch) ->
	compile_host(list_to_binary(HostMatch));
compile_host(HostMatch) when is_binary(HostMatch) ->
	compile_rules(HostMatch, $., [], [], <<>>).

compile_paths([], Acc) ->
	lists:reverse(Acc);
compile_paths([{PathMatch, Handler, Opts}|Tail], Acc) ->
	compile_paths([{PathMatch, [], Handler, Opts}|Tail], Acc);
compile_paths([{PathMatch, Fields, Handler, Opts}|Tail], Acc)
		when is_list(PathMatch) ->
	compile_paths([{iolist_to_binary(PathMatch),
		Fields, Handler, Opts}|Tail], Acc);
compile_paths([{'_', Fields, Handler, Opts}|Tail], Acc) ->
	compile_paths(Tail, [{'_', Fields, Handler, Opts}] ++ Acc);
compile_paths([{<< $/, PathMatch/bits >>, Fields, Handler, Opts}|Tail],
		Acc) ->
	PathRules = compile_rules(PathMatch, $/, [], [], <<>>),
	Paths = [{lists:reverse(R), Fields, Handler, Opts} || R <- PathRules],
	compile_paths(Tail, Paths ++ Acc);
compile_paths([{PathMatch, _, _, _}|_], _) ->
	error({badarg, "The following route MUST begin with a slash: "
		++ binary_to_list(PathMatch)}).

compile_rules(<<>>, _, Segments, Rules, <<>>) ->
	[Segments|Rules];
compile_rules(<<>>, _, Segments, Rules, Acc) ->
	[[Acc|Segments]|Rules];
compile_rules(<< S, Rest/bits >>, S, Segments, Rules, <<>>) ->
	compile_rules(Rest, S, Segments, Rules, <<>>);
compile_rules(<< S, Rest/bits >>, S, Segments, Rules, Acc) ->
	compile_rules(Rest, S, [Acc|Segments], Rules, <<>>);
compile_rules(<< $:, Rest/bits >>, S, Segments, Rules, <<>>) ->
	{NameBin, Rest2} = compile_binding(Rest, S, <<>>),
	Name = binary_to_atom(NameBin, utf8),
	compile_rules(Rest2, S, Segments, Rules, Name);
compile_rules(<< $:, _/bits >>, _, _, _, _) ->
	error(badarg);
compile_rules(<< $[, $., $., $., $], Rest/bits >>, S, Segments, Rules, Acc)
		when Acc =:= <<>> ->
	compile_rules(Rest, S, ['...'|Segments], Rules, Acc);
compile_rules(<< $[, $., $., $., $], Rest/bits >>, S, Segments, Rules, Acc) ->
	compile_rules(Rest, S, ['...', Acc|Segments], Rules, Acc);
compile_rules(<< $[, S, Rest/bits >>, S, Segments, Rules, Acc) ->
	compile_brackets(Rest, S, [Acc|Segments], Rules);
compile_rules(<< $[, Rest/bits >>, S, Segments, Rules, <<>>) ->
	compile_brackets(Rest, S, Segments, Rules);
%% Open bracket in the middle of a segment.
compile_rules(<< $[, _/bits >>, _, _, _, _) ->
	error(badarg);
%% Missing an open bracket.
compile_rules(<< $], _/bits >>, _, _, _, _) ->
	error(badarg);
compile_rules(<< C, Rest/bits >>, S, Segments, Rules, Acc) ->
	compile_rules(Rest, S, Segments, Rules, << Acc/binary, C >>).

%% Everything past $: until the segment separator ($. for hosts,
%% $/ for paths) or $[ or $] or end of binary is the binding name.
compile_binding(<<>>, _, <<>>) ->
	error(badarg);
compile_binding(Rest = <<>>, _, Acc) ->
	{Acc, Rest};
compile_binding(Rest = << C, _/bits >>, S, Acc)
		when C =:= S; C =:= $[; C =:= $] ->
	{Acc, Rest};
compile_binding(<< C, Rest/bits >>, S, Acc) ->
	compile_binding(Rest, S, << Acc/binary, C >>).

compile_brackets(Rest, S, Segments, Rules) ->
	{Bracket, Rest2} = compile_brackets_split(Rest, <<>>, 0),
	Rules1 = compile_rules(Rest2, S, Segments, [], <<>>),
	Rules2 = compile_rules(<< Bracket/binary, Rest2/binary >>,
		S, Segments, [], <<>>),
	Rules ++ Rules2 ++ Rules1.

%% Missing a close bracket.
compile_brackets_split(<<>>, _, _) ->
	error(badarg);
%% Make sure we don't confuse the closing bracket we're looking for.
compile_brackets_split(<< C, Rest/bits >>, Acc, N) when C =:= $[ ->
	compile_brackets_split(Rest, << Acc/binary, C >>, N + 1);
compile_brackets_split(<< C, Rest/bits >>, Acc, N) when C =:= $], N > 0 ->
	compile_brackets_split(Rest, << Acc/binary, C >>, N - 1);
%% That's the right one.
compile_brackets_split(<< $], Rest/bits >>, Acc, 0) ->
	{Acc, Rest};
compile_brackets_split(<< C, Rest/bits >>, Acc, N) ->
	compile_brackets_split(Rest, << Acc/binary, C >>, N).

-spec execute(Req, Env)
	-> {ok, Req, Env} | {stop, pos_integer(), Req}
	when Req::req(), Env::env().
execute(Req=#{host := Host, path := Path}, Env=#{dispatch := Dispatch}) ->
	case match(Dispatch, Host, Path) of
		{ok, Handler, HandlerOpts, Bindings, HostInfo, PathInfo} ->
			{ok, Req#{
				host_info => HostInfo,
				path_info => PathInfo,
				bindings => Bindings
			}, Env#{
				handler => Handler,
				handler_opts => HandlerOpts
			}};
		{error, notfound, host} ->
			{stop, 400, Req};
		{error, badrequest, path} ->
			{stop, 400, Req};
		{error, notfound, path} ->
			{stop, 404, Req}
	end.

%% Internal.

%% Match hostname tokens and path tokens against dispatch rules.
%%
%% It is typically used for matching tokens for the hostname and path of
%% the request against a global dispatch rule for your listener.
%%
%% Dispatch rules are a list of <em>{Hostname, PathRules}</em> tuples, with
%% <em>PathRules</em> being a list of <em>{Path, HandlerMod, HandlerOpts}</em>.
%%
%% <em>Hostname</em> and <em>Path</em> are match rules and can be either the
%% atom <em>'_'</em>, which matches everything, `<<"*">>', which match the
%% wildcard path, or a list of tokens.
%%
%% Each token can be either a binary, the atom <em>'_'</em>,
%% the atom '...' or a named atom. A binary token must match exactly,
%% <em>'_'</em> matches everything for a single token, <em>'...'</em> matches
%% everything for the rest of the tokens and a named atom will bind the
%% corresponding token value and return it.
%%
%% The list of hostname tokens is reversed before matching. For example, if
%% we were to match "www.ninenines.eu", we would first match "eu", then
%% "ninenines", then "www". This means that in the context of hostnames,
%% the <em>'...'</em> atom matches properly the lower levels of the domain
%% as would be expected.
%%
%% When a result is found, this function will return the handler module and
%% options found in the dispatch list, a key-value list of bindings and
%% the tokens that were matched by the <em>'...'</em> atom for both the
%% hostname and path.
-spec match(dispatch_rules(), Host::binary() | tokens(), Path::binary())
	-> {ok, module(), any(), bindings(),
		HostInfo::undefined | tokens(),
		PathInfo::undefined | tokens()}
	| {error, notfound, host} | {error, notfound, path}
	| {error, badrequest, path}.
match([], _, _) ->
	{error, notfound, host};
%% If the host is '_' then there can be no constraints.
match([{'_', [], PathMatchs}|_Tail], _, Path) ->
	match_path(PathMatchs, undefined, Path, []);
match([{HostMatch, Fields, PathMatchs}|Tail], Tokens, Path)
		when is_list(Tokens) ->
	case list_match(Tokens, HostMatch, []) of
		false ->
			match(Tail, Tokens, Path);
		{true, Bindings, HostInfo} ->
			HostInfo2 = case HostInfo of
				undefined -> undefined;
				_ -> lists:reverse(HostInfo)
			end,
			case check_constraints(Fields, Bindings) of
				{ok, Bindings2} ->
					match_path(PathMatchs, HostInfo2, Path, Bindings2);
				nomatch ->
					match(Tail, Tokens, Path)
			end
	end;
match(Dispatch, Host, Path) ->
	match(Dispatch, split_host(Host), Path).

-spec match_path([dispatch_path()],
	HostInfo::undefined | tokens(), binary() | tokens(), bindings())
	-> {ok, module(), any(), bindings(),
		HostInfo::undefined | tokens(),
		PathInfo::undefined | tokens()}
	| {error, notfound, path} | {error, badrequest, path}.
match_path([], _, _, _) ->
	{error, notfound, path};
%% If the path is '_' then there can be no constraints.
match_path([{'_', [], Handler, Opts}|_Tail], HostInfo, _, Bindings) ->
	{ok, Handler, Opts, Bindings, HostInfo, undefined};
match_path([{<<"*">>, _, Handler, Opts}|_Tail], HostInfo, <<"*">>, Bindings) ->
	{ok, Handler, Opts, Bindings, HostInfo, undefined};
match_path([{PathMatch, Fields, Handler, Opts}|Tail], HostInfo, Tokens,
		Bindings) when is_list(Tokens) ->
	case list_match(Tokens, PathMatch, Bindings) of
		false ->
			match_path(Tail, HostInfo, Tokens, Bindings);
		{true, PathBinds, PathInfo} ->
			case check_constraints(Fields, PathBinds) of
				{ok, PathBinds2} ->
					{ok, Handler, Opts, PathBinds2, HostInfo, PathInfo};
				nomatch ->
					match_path(Tail, HostInfo, Tokens, Bindings)
			end
	end;
match_path(_Dispatch, _HostInfo, badrequest, _Bindings) ->
	{error, badrequest, path};
match_path(Dispatch, HostInfo, Path, Bindings) ->
	match_path(Dispatch, HostInfo, split_path(Path), Bindings).

check_constraints([], Bindings) ->
	{ok, Bindings};
check_constraints([Field|Tail], Bindings) when is_atom(Field) ->
	check_constraints(Tail, Bindings);
check_constraints([Field|Tail], Bindings) ->
	Name = element(1, Field),
	case lists:keyfind(Name, 1, Bindings) of
		false ->
			check_constraints(Tail, Bindings);
		{_, Value} ->
			Constraints = element(2, Field),
			case plug_chatterbox_constraints:validate(Value, Constraints) of
				true ->
					check_constraints(Tail, Bindings);
				{true, Value2} ->
					Bindings2 = lists:keyreplace(Name, 1, Bindings,
						{Name, Value2}),
					check_constraints(Tail, Bindings2);
				false ->
					nomatch
			end
	end.

-spec split_host(binary()) -> tokens().
split_host(Host) ->
	split_host(Host, []).

split_host(Host, Acc) ->
	case binary:match(Host, <<".">>) of
		nomatch when Host =:= <<>> ->
			Acc;
		nomatch ->
			[Host|Acc];
		{Pos, _} ->
			<< Segment:Pos/binary, _:8, Rest/bits >> = Host,
			false = byte_size(Segment) == 0,
			split_host(Rest, [Segment|Acc])
	end.

%% Following RFC2396, this function may return path segments containing any
%% character, including <em>/</em> if, and only if, a <em>/</em> was escaped
%% and part of a path segment.
-spec split_path(binary()) -> tokens() | badrequest.
split_path(<< $/, Path/bits >>) ->
	split_path(Path, []);
split_path(_) ->
	badrequest.

split_path(Path, Acc) ->
	try
		case binary:match(Path, <<"/">>) of
			nomatch when Path =:= <<>> ->
				remove_dot_segments(lists:reverse([plug_chatterbox_uri:urldecode(S) || S <- Acc]), []);
			nomatch ->
				remove_dot_segments(lists:reverse([plug_chatterbox_uri:urldecode(S) || S <- [Path|Acc]]), []);
			{Pos, _} ->
				<< Segment:Pos/binary, _:8, Rest/bits >> = Path,
				split_path(Rest, [Segment|Acc])
		end
	catch
		error:badarg ->
			badrequest
	end.

remove_dot_segments([], Acc) ->
	lists:reverse(Acc);
remove_dot_segments([<<".">>|Segments], Acc) ->
	remove_dot_segments(Segments, Acc);
remove_dot_segments([<<"..">>|Segments], Acc=[]) ->
	remove_dot_segments(Segments, Acc);
remove_dot_segments([<<"..">>|Segments], [_|Acc]) ->
	remove_dot_segments(Segments, Acc);
remove_dot_segments([S|Segments], Acc) ->
	remove_dot_segments(Segments, [S|Acc]).

-spec list_match(tokens(), dispatch_match(), bindings())
	-> {true, bindings(), undefined | tokens()} | false.
%% Atom '...' matches any trailing path, stop right now.
list_match(List, ['...'], Binds) ->
	{true, Binds, List};
%% Atom '_' matches anything, continue.
list_match([_E|Tail], ['_'|TailMatch], Binds) ->
	list_match(Tail, TailMatch, Binds);
%% Both values match, continue.
list_match([E|Tail], [E|TailMatch], Binds) ->
	list_match(Tail, TailMatch, Binds);
%% Bind E to the variable name V and continue,
%% unless V was already defined and E isn't identical to the previous value.
list_match([E|Tail], [V|TailMatch], Binds) when is_atom(V) ->
	case lists:keyfind(V, 1, Binds) of
		{_, E} ->
			list_match(Tail, TailMatch, Binds);
		{_, _} ->
			false;
		false ->
			list_match(Tail, TailMatch, [{V, E}|Binds])
	end;
%% Match complete.
list_match([], [], Binds) ->
	{true, Binds, undefined};
%% Values don't match, stop.
list_match(_List, _Match, _Binds) ->
	false.
