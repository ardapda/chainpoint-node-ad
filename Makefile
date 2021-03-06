# First target in the Makefile is the default.
all: help

# without this 'source' won't work.
SHELL := /bin/bash

# Get the location of this makefile.
ROOT_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

# Specify the binary dependencies
REQUIRED_BINS := docker docker-compose gcloud
$(foreach bin,$(REQUIRED_BINS),\
    $(if $(shell command -v $(bin) 2> /dev/null),$(),$(error Please install `$(bin)` first!)))

.PHONY : help
help : Makefile
	@sed -n 's/^##//p' $<

## up              : Start Node
.PHONY : up
up: build-config yarn build
	docker-compose up -d --no-build

## down            : Shutdown Node
.PHONY : down
down:
	docker-compose down

## restart         : Restart Node
.PHONY : restart
restart: down up

## logs            : Tail Node logs
.PHONY : logs
logs:
	docker-compose logs -f -t | grep chainpoint-node

## logs-redis      : Tail Redis logs
.PHONY : logs-redis
logs-redis:
	docker-compose logs -f -t | grep redis

## logs-postgres   : Tail PostgreSQL logs
.PHONY : logs-postgres
logs-postgres:
	docker-compose logs -f -t | grep postgres

## logs-all        : Tail all logs
.PHONY : logs-all
logs-all:
	docker-compose logs -f -t

## ps              : View running processes
.PHONY : ps
ps:
	docker-compose ps

## build           : Build Node image
.PHONY : build
build: tor-exit-nodes
	docker build -t chainpoint-node .
	docker tag chainpoint-node gcr.io/chainpoint-registry/chainpoint-node
	docker container prune -f
	docker-compose build

## build-config    : Copy the .env config from .env.sample
.PHONY : build-config
build-config:
	@[ ! -f ./.env ] && \
	cp .env.sample .env && \
	echo 'Copied config .env.sample to .env' || true

## push            : Push Docker images to public google container registry
.PHONY : push
push:
	gcloud docker -- push gcr.io/chainpoint-registry/chainpoint-node

## pull            : Pull Docker images
.PHONY : pull
pull:
	docker-compose pull

## git-pull        : Git pull latest
.PHONY : git-pull
git-pull:
	@git pull --all

## upgrade         : Same as `make down && git pull && make up`
.PHONY : upgrade
upgrade: down git-pull up

## clean           : Shutdown and **destroy** all local Node data
.PHONY : clean
clean: down
	@rm -rf ./.data/*

## yarn            : Install Node Javascript dependencies
.PHONY : yarn
yarn:
	docker run -it --rm --volume "$(PWD)":/usr/src/app --volume /var/run/docker.sock:/var/run/docker.sock --volume ~/.docker:/root/.docker --volume "$(PWD)":/wd --workdir /wd gcr.io/chainpoint-registry/chainpoint-node:latest yarn

## postgres        : Connect to the local PostgreSQL with `psql`
.PHONY : postgres
postgres:
	@docker-compose up -d postgres
	@sleep 6
	@docker exec -it postgres-node-src psql -U chainpoint

## redis           : Connect to the local Redis with `redis-cli`
.PHONY : redis
redis:
	@docker-compose up -d redis
	@sleep 2
	@docker exec -it redis-node-src redis-cli

## auth-keys       : Export HMAC auth keys from PostgreSQL
.PHONY : auth-keys
auth-keys:
	@docker-compose up -d postgres	
	@sleep 6
	@docker exec -it postgres-node-src psql -U chainpoint -c 'SELECT * FROM hmackeys;'

## auth-key-update : Update HMAC auth key with `KEY` (hex string) var. Example `make auth-key-update KEY=mysecrethexkey`
.PHONY : auth-key-update
auth-key-update: guard-KEY
	@docker-compose up -d postgres
	@sleep 6
	@source .env && docker exec -it postgres-node-src psql -U chainpoint -c "INSERT INTO hmackeys (tnt_addr, hmac_key, version, created_at, updated_at) VALUES (LOWER('$$NODE_TNT_ADDRESS'), LOWER('$(KEY)'), 1, clock_timestamp(), clock_timestamp()) ON CONFLICT (tnt_addr) DO UPDATE SET hmac_key = LOWER('$(KEY)'), version = 1, updated_at = clock_timestamp()"
	make restart

## auth-key-delete : Delete HMAC auth key with `NODE_TNT_ADDRESS` var. Example `make auth-key-delete NODE_TNT_ADDRESS=0xmyethaddress`
.PHONY : auth-key-delete
auth-key-delete: guard-NODE_TNT_ADDRESS
	@docker-compose up -d postgres
	@sleep 6
	@docker exec -it postgres-node-src psql -U chainpoint -c "DELETE FROM hmackeys WHERE tnt_addr = LOWER('$(NODE_TNT_ADDRESS)')"
	make restart

## calendar-delete : Delete all calendar data for this Node
.PHONY : calendar-delete
calendar-delete: 
	@docker-compose up -d postgres
	@sleep 6
	@docker exec -it postgres-node-src psql -U chainpoint -c "DELETE FROM calendar"
	make restart

guard-%:
	@ if [ "${${*}}" = "" ]; then \
		echo "Environment variable $* not set"; \
		exit 1; \
	fi

## tor-exit-nodes  : Update static list of Exit Nodes
.PHONY : tor-exit-nodes
tor-exit-nodes:
	curl -s https://check.torproject.org/exit-addresses | grep ExitAddress | cut -d' ' -f2 > ./tor-exit-nodes.txt
