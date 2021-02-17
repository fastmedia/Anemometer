BINARY_NAME=app
LINUX_BINARY_DIR=build
DEPLOYDIR=$(shell mktemp -d)
AWSCMD=aws
LDFLAGS=-ldflags "-s -w"
TAG=latest
ECR_NAME_PREFIX=prod
AWS_ACCOUNT_ID=804467274111
APP_NAME=anemometer

help:  ## This help
		@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

build: ## Build app
		docker build -t $(APP_NAME) -f ./Dockerfile .

upload: build ## Deploy app
		docker tag $(APP_NAME):latest $(AWS_ACCOUNT_ID).dkr.ecr.ap-northeast-1.amazonaws.com/$(ECR_NAME_PREFIX)-$(APP_NAME):$(TAG)
			docker push $(AWS_ACCOUNT_ID).dkr.ecr.ap-northeast-1.amazonaws.com/$(ECR_NAME_PREFIX)-$(APP_NAME):$(TAG)

.PHONY: help build upload
	.DEFAULT_GOAL := help

