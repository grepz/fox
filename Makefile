CC = $(shell which rebar3 2> /dev/null || which ./rebar3)

compile:
	$(CC) compile

eunit:
	$(CC) eunit

ct:
	$(CC) ct

tests: eunit ct

console:
	erl -pa _build/default/lib/*/ebin -s fox test_run

d:
	$(CC) dialyzer

clean:
	$(CC) clean

clean-all:
	rm -rf _build
	rm rebar.lock

