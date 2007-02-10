-module(smtp_server_session).
%% Somewhat loosely based on rfc 2821.

%% FIXME: SMTP AUTH

-behaviour(gen_server).

-export([accept_and_start/1]).
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2, handle_info/2]).

accept_and_start(LSock) ->
    spawn_link(fun () ->
		       case gen_tcp:accept(LSock) of
			   {ok, Sock} ->
			       accept_and_start(LSock),
			       {ok, Pid} = gen_server:start(?MODULE, [Sock], []),
			       gen_tcp:controlling_process(Sock, Pid),
			       gen_server:cast(Pid, socket_control_transferred);
			   {error, Reason} ->
			       exit({error, Reason})
		       end
	       end).

%---------------------------------------------------------------------------

-record(session, {socket, mode, forward_path, data_buffer}).

reply_line(Code, Text, false) ->
    [integer_to_list(Code), " ", Text, "\r\n"];
reply_line(Code, Text, true) ->
    [integer_to_list(Code), "-", Text, "\r\n"].

reply(Code, Text, State = #session{socket = Socket}) ->
    gen_tcp:send(Socket, reply_line(Code, Text, false)),
    State.

reply_multi(Code, [], State = #session{socket = Socket}) ->
    gen_tcp:send(Socket, reply_line(Code, "nothing to see here, move along", false)),
    State;
reply_multi(Code, [Text], State = #session{socket = Socket}) ->
    gen_tcp:send(Socket, reply_line(Code, Text, false)),
    State;
reply_multi(Code, [Text | More], State = #session{socket = Socket}) ->
    gen_tcp:send(Socket, reply_line(Code, Text, true)),
    reply_multi(Code, More, State).

reset_buffers(State) ->
    State#session{forward_path = undefined,
		  data_buffer = []}.

address_to_mailbox(Address) ->
    case regexp:match(Address, "[^@]+@") of
	{match, 1, Length} ->
	    string:substr(Address, 1, Length - 1);
	_ ->
	    Address
    end.

split_path_from_params(Str) ->
    case regexp:match(Str, "<[^>]*>") of
	{match, 1, Length} ->
	    Address = string:substr(Str, 2, Length - 2),
	    Params = string:strip(string:substr(Str, Length + 1), left),
	    {address_to_mailbox(Address), Params};
	_ ->
	    case httpd_util:split(Str, " ", 2) of
		{ok, [Address]} ->
		    {address_to_mailbox(Address), ""};
		{ok, [Address, Params]} ->
		    {address_to_mailbox(Address), Params}
	    end
    end.

parse_path_and_parameters(PrefixRegexp, Data) ->
    case regexp:first_match(Data, PrefixRegexp) of
	nomatch ->
	    unintelligible;
	{match, 1, Length} ->
	    PathAndParams = string:strip(string:substr(Data, Length + 1), left),
	    {Path, Params} = split_path_from_params(PathAndParams),
	    {ok, Path, Params}
    end.

handle_command_line(Line, State) ->
    {Command, Data} = case httpd_util:split(Line, " ", 2) of
			  {ok, [C]} -> {httpd_util:to_upper(C), ""};
			  {ok, [C, D]} -> {httpd_util:to_upper(C), D}
		      end,
    handle_command(Command, Data, State).

handle_command("QUIT", _ClientDomain, State) ->
    {stop, normal, reply(221, "Goodbye",
			 reset_buffers(State))};

handle_command("EHLO", _ClientDomain, State) ->
    ServerDomain = "bogus.smtp.server.domain", %% FIXME
    {noreply, reply(250, ServerDomain ++ " You have reached an SMTP service",
		    reset_buffers(State))};

handle_command("HELO", _ClientDomain, State) ->
    ServerDomain = "bogus.smtp.server.domain", %% FIXME
    {noreply, reply(250, ServerDomain ++ " You have reached an SMTP service",
		    reset_buffers(State))};

handle_command("MAIL", _FromReversePathAndMailParameters, State) ->
    {noreply, reply(250, "OK",
		    reset_buffers(State))};

handle_command("RCPT", ToForwardPathAndMailParameters, State) ->
    case parse_path_and_parameters("[tT][oO]:", ToForwardPathAndMailParameters) of
	unintelligible ->
	    {noreply, reply(553, "Unintelligible forward-path", State)};
	{ok, Path, _Params} ->
	    {noreply, reply(250, "OK",
			    State#session{forward_path = Path})}
    end;

handle_command("DATA", _Junk, State = #session{forward_path = Path}) ->
    if
	Path == undefined ->
	    {noreply, reply(503, "RCPT first", State)};
	true ->
	    {noreply, reply(354, "Go ahead", State#session{mode = data})}
    end;

handle_command("RSET", _Junk, State) ->
    {noreply, reply(250, "OK",
		    reset_buffers(State))};

handle_command("VRFY", _UserOrMailboxPossibly, State) ->
    {noreply, reply(252, "Will not VRFY", State)};

handle_command("EXPN", _MailingListPossibly, State) ->
    {noreply, reply(252, "Will not EXPN", State)};

handle_command("HELP", _MaybeCommand, State) ->
    {noreply, reply(502, "Unimplemented", State)};

handle_command("NOOP", _Junk, State) ->
    {noreply, reply(250, "OK", State)};

handle_command(Command, _Data, State) ->
    {noreply, reply(500, "Unsupported command " ++ Command, State)}.

handle_data_line(".\r\n", State = #session{forward_path = ForwardPath,
					   data_buffer = DataBuffer}) ->
    {Code, Text} = case deliver(ForwardPath, DataBuffer) of
		       ok -> {250, "OK"};
		       _ -> {554, "Transaction failed"}
		   end,
    {noreply, reply(Code, Text,
		    reset_buffers(State#session{mode = command}))};
handle_data_line("." ++ Line, State = #session{data_buffer = Buffer}) ->
    {noreply, State#session{data_buffer = [Line | Buffer]}};
handle_data_line(Line, State = #session{data_buffer = Buffer}) ->
    {noreply, State#session{data_buffer = [Line | Buffer]}}.

strip_crlf(S) ->
    lists:reverse(strip_crlf1(lists:reverse(S))).

strip_crlf1([$\n, $\r | S]) -> S.

deliver(Mailbox, DataLinesRev) ->
    io:format("Delivering ~p~n~p~n", [Mailbox, DataLinesRev]),
    ok.

%---------------------------------------------------------------------------

init([Sock]) ->
    {ok, #session{socket = Sock,
		  mode = initializing,
		  forward_path = undefined,
		  data_buffer = []}}.

terminate(_Reason, #session{socket = Sock}) ->
    gen_tcp:close(Sock),
    ok.

code_change(_OldVsn, State, _Extra) ->
    State.

handle_call(Request, _From, State) ->
    {stop, {bad_call, Request}, State}.

handle_cast(socket_control_transferred, State = #session{socket = Sock}) ->
    inet:setopts(Sock, [{active, true}]),
    {noreply, reply(220, "Hi there", State#session{mode = command})};

handle_cast(Request, State) ->
    {stop, {bad_cast, Request}, State}.

handle_info({tcp, _Sock, FullLine}, State = #session{mode = command}) ->
    handle_command_line(strip_crlf(FullLine), State);

handle_info({tcp, _Sock, FullLine}, State = #session{mode = data}) ->
    handle_data_line(FullLine, State);

handle_info({tcp_closed, _Sock}, State) ->
    error_logger:warning_msg("SMTP session closed without warning"),
    {stop, normal, State};

handle_info({tcp_error, _Sock, Reason}, State) ->
    error_logger:warning_msg("SMTP session closed with socket error ~p", [Reason]),
    {stop, normal, State};

handle_info(Message, State) ->
    {stop, {bad_info, Message}, State}.