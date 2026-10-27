# Shortcuts for running things locally. CI runs the same commands.
# Usage: make help

LIVE      := infra/live
BOOTSTRAP := infra/bootstrap
# Read the bucket and region from the bootstrap stack's outputs.
STATE_BUCKET = $(shell terraform -chdir=$(BOOTSTRAP) output -raw state_bucket)
AWS_REGION   = $(shell terraform -chdir=$(BOOTSTRAP) output -raw aws_region)

.PHONY: help test bootstrap init plan apply deploy-site destroy fmt validate lock

help: ## Show this help
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

test: ## Run the site tests
	npm install --no-audit --no-fund
	npm test

bootstrap: ## One-time setup: state bucket, CI roles, GitHub settings (needs AWS creds + GITHUB_TOKEN)
	terraform -chdir=$(BOOTSTRAP) init
	terraform -chdir=$(BOOTSTRAP) apply

init: ## Connect the live stack to its remote state
	terraform -chdir=$(LIVE) init -reconfigure \
	  -backend-config="bucket=$(STATE_BUCKET)" \
	  -backend-config="region=$(AWS_REGION)"

plan: init ## Show what would change in AWS
	terraform -chdir=$(LIVE) plan

apply: init ## Change AWS to match the code (normally CI does this)
	terraform -chdir=$(LIVE) apply

deploy-site: ## Upload site/ and clear the CDN cache (normally CI does this)
	aws s3 sync site/ s3://$$(terraform -chdir=$(LIVE) output -raw content_bucket) --delete
	aws cloudfront create-invalidation --distribution-id $$(terraform -chdir=$(LIVE) output -raw cdn_id) --paths "/*"

destroy: init ## Delete everything in the live stack
	terraform -chdir=$(LIVE) destroy

fmt: ## Format all Terraform files
	terraform fmt -recursive infra

validate: ## Check Terraform syntax without touching AWS
	terraform -chdir=$(LIVE) init -backend=false
	terraform -chdir=$(LIVE) validate

lock: ## Record provider checksums for Linux (CI) and Mac/Windows, then commit the lock files
	terraform -chdir=$(LIVE) providers lock -platform=linux_amd64 -platform=darwin_arm64 -platform=darwin_amd64 -platform=windows_amd64
	terraform -chdir=$(BOOTSTRAP) providers lock -platform=linux_amd64 -platform=darwin_arm64 -platform=darwin_amd64 -platform=windows_amd64
