NAME=kelly

all: generate

get-deps:
	@./rebar get-deps

clean:
	@./rebar clean

dialyze:
	@./rebar clean
	@./rebar compile debug_info=1
	@./rebar dialyze skip_deps=true
	@./rebar clean

build-plt:
	@./rebar build-plt skip_deps=true

compile: get-deps
	@./rebar compile

generate: compile
	@rm -rf ./rel/$(NAME)
	@./rebar generate

compile-fast:
	@./rebar compile

generate-fast: compile-fast
	@rm -rf ./rel/$(NAME)
	@./rebar generate

console:
	./rel/$(NAME)/bin/$(NAME) console

develop:
	./rel/$(NAME)/bin/$(NAME) develop

gdb:
	./rel/$(NAME)/bin/$(NAME) gdb

release: generate
	./rel/create-release.sh

update-deps:
	./rebar update-deps

ci: funnel kannel smppsim just generate
	./rel/$(NAME)/bin/$(NAME) start
	sleep 2
	./rel/$(NAME)/bin/$(NAME) ping
	./rel/files/kelly_http_configure
	cat ./rel/$(NAME)/log/error.log
	eval "lsof -i :8080"
	mongo --eval 's = db.stats(); printjson(s)'

funnel:
	# eval "wget https://dl.dropbox.com/u/85105941/funnel_mini_ubuntu12.10_x86_64.tar.gz"
	# tar xzf funnel_mini_ubuntu12.10_x86_64.tar.gz
	# ./funnel_mini/bin/funnel start
	# sleep 3
	# ./funnel_mini/bin/funnel ping

kannel:

smppsim:
	eval "wget https://dl.dropbox.com/u/85105941/SMPPSim.tar.gz"
	tar xzf ./SMPPSim.tar.gz
	chmod +x ./SMPPSim/startsmppsim.sh
	cp ./rel/files/smppsim.props ./SMPPSim/conf/
	./SMPPSim/startsmppsim.sh 2> ./SMPPSim/smppsim.log &
	cat ./SMPPSim/smppsim.log

just:
	eval "git clone https://github.com/PowerMeMobile/just_mini_rel.git"
	make -C ./just_mini_rel
	./just_mini_rel/bin/just start
	sleep 3
	./just_mini_rel/bin/just ping