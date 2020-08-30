-module(register_handler).

%trails
-behaviour(trails_handler).
-export([trails/0]).

trails() ->
  Metadata =
    #{get =>
      #{parameters => [
          #{name => <<"token">>,
            description => <<"Token from POST">>,
            in => <<"path">>,
            required => true,
            schema =>
              #{type => string,
                example => <<"fhdjklehurigreiu2984673r84ogfr9u32">>
              }
          }
        ],
        description => "Gets echo var from the server",
        responses => #{
          <<"200">> => #{
            description => <<"Gets echo var from the server 200 OK">>,
            content => #{
              'text/plain' =>
                #{schema => #{
                    type => string
                  }
                }
            }
          }
        }
      },
      put =>
      #{description => "First step in registering an account.",
        parameters => [
          #{name => <<"email">>,
            description => <<"Email Address">>,
            in => <<"path">>,
            required => true,
            schema =>
              #{type => string,
                example => <<"me@mydomain.com">>
              }
          },
          #{name => <<"pass">>,
            description => <<"Password - minimum 6 characters">>,
            in => <<"path">>,
            required => true, 
            schema =>
              #{type => string,
                example => <<"aB^D3Fg">>
              }
          },
          #{name => <<"fname">>,
            description => <<"First Name">>,
            in => <<"path">>,
            required => false,
            schema =>
              #{type => string,
                example => <<"John">>
              }
          },
          #{name => <<"lname">>,
            description => <<"Last Name">>,
            in => <<"path">>,
            required => false,
            schema =>
              #{type => string,
                example => <<"Smith">>
              }
          }
        ]
      }
    },
  [trails:trail("/", register_handler, [], Metadata)].

%% REST Callbacks
-export([init/2]).
-export([allowed_methods/2]).
-export([content_types_provided/2]).
-export([content_types_accepted/2]).
-export([resource_exists/2]).

%% Callback Callbacks
-export([register_from_json/2]).
-export([register_from_text/2]).

%% Helpes
-import(helper, [get_body/2, get_model/3, reply/3, pwd2hash/1]).

%% Cowboy REST callbacks
init(Req, State) ->
    {cowboy_rest, Req, State}.

allowed_methods(Req, State) ->
    {[<<"GET">>, <<"POST">>], Req, State}. 

content_types_provided(Req, State) ->
    {[
        {<<"text/plain">>, register_from_text},
        {<<"text/html">>, register_from_text}
    ], Req, State}.

content_types_accepted(Req, State) ->
    {[
        {<<"application/json">>, register_from_json}
    ], Req, State}.

resource_exists(Req, State) ->
    case cowboy_req:method(Req) of
        <<"GET">> -> {true, Req, State};
        <<"POST">> -> {false, Req, State}
    end.

register_from_json(Req, State) ->
    {ok, Body, Req1} = cowboy_req:read_urlencoded_body(Req),

    %% Check request body
    case get_body(Body, Req1) of
        {ok, Input, _Req} ->
            %% Validate body json and fields
            Model = [
                {<<"email">>, required, string, email, [non_empty,
                    fun(V) ->
                        validator:email(V)
                    end
                ]},
                {<<"pass">>, required, string, pass, [non_empty, 
                    fun(V) -> 
                        validator:min_length(6, V)
                    end
                ]},
                {<<"fname">>, required, string, fname, [non_empty]},
                {<<"lname">>, required, string, lname, [non_empty]}                
            ],
            Emodel = get_model(Input, Model, Req1),

            %% Check model result
            case Emodel of
                {error, Reason} ->
                    Req3 = reply(412, {Reason}, Req1),
                    {false, Req3, State};
                {error, empty, Req4} ->
                    {false, Req4, State};
                {ok, _} ->

                    %% Perform Registration
                    case registration(Emodel, Req1) of
                        {ok, User, Req5} ->
                            {true, reply(200, User, Req5), State};
                        {error, Req6} ->
                            {false, Req6, State}
                    end

            end;

        {error, empty, Req2} -> 
            {false, Req2, State}

    end.

register_from_text(Req, State) ->
    #{token := Token} = cowboy_req:match_qs([{token, nonempty, undefined}], Req),
    case Token of
        undefined ->
            {[], reply(400, <<"Token mismatch">>, Req), State};
        _Token ->
            case cowboy_session:get(<<"register">>, Req) of
                {undefined, Req1} ->
                    {[], reply(400, <<"Token expired">>, Req1), State};
                {Register, Req1} ->
                    SToken = maps:get(token, Register),
                    erlang:display([Token, SToken]),
                    case SToken =:= Token of
                        true ->
                            {ok, Req2} = cowboy_session:set(register, undefined, Req1),
                            case persist:check_user(pgdb, maps:get(email, Register)) of
                                false ->
                                    Email = maps:get(email, Register),
                                    Pass = maps:get(pass, Register),
                                    Fname = maps:get(fname, Register),
                                    Lname = maps:get(lname, Register),
                                    case persist:add_user(pgdb, Email, Fname, Lname, Pass) of
                                        {ok, 1} ->
                                            User = #{email => Email, fname => Fname, lname => Lname},
                                            {ok, Req3} = cowboy_session:set(<<"user">>, User, Req2),
                                            {jiffy:encode(User), Req3, State};
                                        _ ->
                                            {[], reply(500, <<"Cannot add new user in database">>, Req2)} 
                                    end;
                                _ ->
                                    {[], reply(400, <<"User already exists">>, Req2)} 
                            end;
                        false -> 
                            {[], reply(400, <<"Wrong token!">>, Req1), State}
                    end
            end
    end.

%% Registration functions
registration(Emodel, Req) ->
    %% Auth middleware
    case middleware:allready_auth(Req) of
        {false, Req1} ->
            {ok, Data} = Emodel,
            case persist:check_user(pgdb, maps:get(email, Data)) of
                false ->
                    Pass = maps:get(pass, Data),
                    Register_safe_pass = maps:update(pass, pwd2hash(Pass), Data),
                    Register = maps:put(token, random(64), Register_safe_pass),
                    {ok, Req2} = cowboy_session:set(<<"register">>, Register, Req1),
                    {ok, Register, Req2};
                _ ->
                    {error, reply(400, <<"User already exists">>, Req1)}
            end;
        {true, _User, Req3} -> {error, Req3}
    end.

random(Len) ->
    Chrs = list_to_tuple("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"),
    ChrsSize = size(Chrs),
    F = fun(_, R) -> [element(rand:uniform(ChrsSize), Chrs) | R] end,
    list_to_binary(lists:foldl(F, "", lists:seq(1, Len))).

% random() ->
%     base64:encode(crypto:strong_rand_bytes(64)).
