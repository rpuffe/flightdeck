# flightdeck — bootstrap / deploy / destroy targets
# Compatible with GNU Make 3.81 (macOS default): no 4.x features.

TF        := terraform
BOOTSTRAP := bootstrap
REGION    := us-east-1

# Derived at runtime so the account id is never committed anywhere.
ACCOUNT_ID   = $(shell aws sts get-caller-identity --query Account --output text)
STATE_BUCKET = flightdeck-tfstate-$(ACCOUNT_ID)

BACKEND_FLAGS = -backend-config="bucket=$(STATE_BUCKET)" \
                -backend-config="key=bootstrap/terraform.tfstate" \
                -backend-config="region=$(REGION)" \
                -backend-config="use_lockfile=true"

HELLO = examples/hello

HELLO_BACKEND_FLAGS = -backend-config="bucket=$(STATE_BUCKET)" \
                      -backend-config="key=apps/hello/terraform.tfstate" \
                      -backend-config="region=$(REGION)" \
                      -backend-config="use_lockfile=true"

CLUSTER := flightdeck
APP_DOMAIN := fd.robertpuffe.com

.PHONY: fmt validate test plan-bootstrap bootstrap destroy-bootstrap \
        plan-hello deploy-hello destroy-hello \
        ps stop start stop-all start-all \
        new-app check-release prepare-release

# --- Service operations ------------------------------------------------------
# Scale operations are deliberate drift: terraform state keeps desired_count=1,
# so the NEXT DEPLOY of a service restores it. Cheap overnight off-switch, not
# a permanent setting.
#
# stop/start/stop-all/start-all go through the flightdeck-scaler Lambda
# (aws lambda invoke) rather than calling `aws ecs update-service` directly,
# so manual ops use the same desired-count path as the nightly scheduler.
# A stopped app is restarted explicitly from the wake page;
# direct visits remain on the app target group and return 503 while stopped.
# `make ps` stays read-only direct. The scaler Lambda's resource policy grants
# the bootstrap caller permission to invoke this one function.

ps:
	@aws ecs list-services --cluster $(CLUSTER) --query 'serviceArns' --output text | tr '\t' '\n' | awk -F/ '{print $$NF}' | sort | while read s; do \
	  [ -n "$$s" ] || continue; \
	  aws ecs describe-services --cluster $(CLUSTER) --services $$s \
	    --query 'services[0].[serviceName,desiredCount,runningCount]' --output text | \
	  awk '{printf "%-20s desired=%s running=%s  https://%s.$(APP_DOMAIN)\n", $$1, $$2, $$3, $$1}'; \
	done

# Single-line python3 -c body shared by stop/start/stop-all/start-all: reads
# the invoke response JSON from $$tmp, prints one "name -> result" line per
# service (results carry "ok" or an error message per service -- a bad name
# in a batch never aborts the others), and exits non-zero if the Lambda
# itself reported status != "ok". Written as one physical line (no embedded
# newlines) so GNU Make's line-based recipe parsing can't mis-split it --
# multi-line quoted strings inside a Make recipe don't reliably survive
# Make's own line-continuation handling.
PARSE_LAMBDA_RESPONSE = python3 -c 'import json, sys; resp = json.load(open(sys.argv[1])); ok = resp.get("status") == "ok"; print("error:", resp) if not ok else None; [print(n, "->", resp["results"][n]) for n in sorted(resp.get("results", {}))] if ok else None; sys.exit(0 if ok else 1)'

stop:
	@test -n "$(SVC)" || { echo "usage: make stop SVC=<service>   (make ps lists them)"; exit 1; }
	@tmp=$$(mktemp) && \
	if ! aws lambda invoke --function-name flightdeck-scaler \
	    --cli-binary-format raw-in-base64-out \
	    --payload '{"action":"stop","services":["$(SVC)"]}' \
	    "$$tmp" > /dev/null 2>&1; then \
	  echo "error: lambda invoke failed -- does this principal have lambda:InvokeFunction"; \
	  echo "  on flightdeck-scaler? re-apply bootstrap as the intended operator"; \
	  rm -f "$$tmp"; exit 1; \
	fi; \
	$(PARSE_LAMBDA_RESPONSE) "$$tmp"; \
	status=$$?; rm -f "$$tmp"; \
	if [ $$status -eq 0 ]; then echo "note: next deploy of $(SVC) restores desired=1 (terraform owns that value)"; fi; \
	exit $$status

start:
	@test -n "$(SVC)" || { echo "usage: make start SVC=<service>   (make ps lists them)"; exit 1; }
	@tmp=$$(mktemp) && \
	if ! aws lambda invoke --function-name flightdeck-scaler \
	    --cli-binary-format raw-in-base64-out \
	    --payload '{"action":"start","services":["$(SVC)"]}' \
	    "$$tmp" > /dev/null 2>&1; then \
	  echo "error: lambda invoke failed -- does this principal have lambda:InvokeFunction"; \
	  echo "  on flightdeck-scaler? re-apply bootstrap as the intended operator"; \
	  rm -f "$$tmp"; exit 1; \
	fi; \
	$(PARSE_LAMBDA_RESPONSE) "$$tmp"; \
	status=$$?; rm -f "$$tmp"; exit $$status

stop-all:
	@tmp=$$(mktemp) && \
	if ! aws lambda invoke --function-name flightdeck-scaler \
	    --cli-binary-format raw-in-base64-out \
	    --payload '{"action":"stop-all"}' \
	    "$$tmp" > /dev/null 2>&1; then \
	  echo "error: lambda invoke failed -- does this principal have lambda:InvokeFunction"; \
	  echo "  on flightdeck-scaler? re-apply bootstrap as the intended operator"; \
	  rm -f "$$tmp"; exit 1; \
	fi; \
	$(PARSE_LAMBDA_RESPONSE) "$$tmp"; \
	status=$$?; rm -f "$$tmp"; \
	if [ $$status -eq 0 ]; then echo "note: any service's next deploy restores it (terraform owns desired_count)"; fi; \
	exit $$status

start-all:
	@tmp=$$(mktemp) && \
	if ! aws lambda invoke --function-name flightdeck-scaler \
	    --cli-binary-format raw-in-base64-out \
	    --payload '{"action":"start-all"}' \
	    "$$tmp" > /dev/null 2>&1; then \
	  echo "error: lambda invoke failed -- does this principal have lambda:InvokeFunction"; \
	  echo "  on flightdeck-scaler? re-apply bootstrap as the intended operator"; \
	  rm -f "$$tmp"; exit 1; \
	fi; \
	$(PARSE_LAMBDA_RESPONSE) "$$tmp"; \
	status=$$?; rm -f "$$tmp"; exit $$status

fmt:
	$(TF) -chdir=$(BOOTSTRAP) fmt -recursive
	$(TF) fmt -recursive modules examples

validate:
	$(TF) -chdir=$(BOOTSTRAP) init -input=false -backend=false > /dev/null
	$(TF) -chdir=$(BOOTSTRAP) validate
	$(TF) -chdir=modules/fargate-service init -input=false -backend=false > /dev/null
	$(TF) -chdir=modules/fargate-service validate
	$(TF) -chdir=$(HELLO) init -input=false -backend=false > /dev/null
	$(TF) -chdir=$(HELLO) validate

test:
	python3 -m unittest discover -s tests -v

check-release:
	python3 scripts/release_consistency.py $(if $(TAG),--tag $(TAG),)

prepare-release:
	@test -n "$(TAG)" || { echo "usage: make prepare-release TAG=vX.Y.Z"; exit 1; }
	python3 scripts/release_consistency.py --set $(TAG)

# --- Stage 1 worked example -------------------------------------------------

plan-hello:
	$(TF) -chdir=$(HELLO) init -input=false $(HELLO_BACKEND_FLAGS)
	$(TF) -chdir=$(HELLO) plan -var "state_bucket=$(STATE_BUCKET)"

deploy-hello:
	$(TF) -chdir=$(HELLO) init -input=false $(HELLO_BACKEND_FLAGS)
	$(TF) -chdir=$(HELLO) apply -var "state_bucket=$(STATE_BUCKET)"

destroy-hello:
	$(TF) -chdir=$(HELLO) init -input=false $(HELLO_BACKEND_FLAGS)
	$(TF) -chdir=$(HELLO) destroy -var "state_bucket=$(STATE_BUCKET)"

# On the very first run the state bucket doesn't exist yet, and terraform
# refuses to plan/apply with an uninitialized backend block — so the block is
# set aside (backend.tf.off), the run uses the implicit local backend, and
# `bootstrap` migrates state into the bucket afterwards.
plan-bootstrap:
	@if aws s3api head-bucket --bucket $(STATE_BUCKET) 2>/dev/null; then \
		$(TF) -chdir=$(BOOTSTRAP) init -input=false $(BACKEND_FLAGS) && \
		$(TF) -chdir=$(BOOTSTRAP) plan; \
	else \
		echo ">> First run (state bucket absent): planning against local state" && \
		mv $(BOOTSTRAP)/backend.tf $(BOOTSTRAP)/backend.tf.off && \
		$(TF) -chdir=$(BOOTSTRAP) init -input=false -reconfigure; \
		$(TF) -chdir=$(BOOTSTRAP) plan; \
		status=$$?; \
		mv $(BOOTSTRAP)/backend.tf.off $(BOOTSTRAP)/backend.tf; \
		exit $$status; \
	fi

bootstrap:
	@if aws s3api head-bucket --bucket $(STATE_BUCKET) 2>/dev/null; then \
		$(TF) -chdir=$(BOOTSTRAP) init -input=false $(BACKEND_FLAGS) && \
		$(TF) -chdir=$(BOOTSTRAP) apply; \
	else \
		echo ">> First run: applying with local state, then migrating to S3" && \
		mv $(BOOTSTRAP)/backend.tf $(BOOTSTRAP)/backend.tf.off && \
		$(TF) -chdir=$(BOOTSTRAP) init -input=false -reconfigure; \
		$(TF) -chdir=$(BOOTSTRAP) apply; \
		status=$$?; \
		mv $(BOOTSTRAP)/backend.tf.off $(BOOTSTRAP)/backend.tf; \
		if [ $$status -ne 0 ]; then exit $$status; fi; \
		$(TF) -chdir=$(BOOTSTRAP) init -input=false -migrate-state -force-copy $(BACKEND_FLAGS) && \
		rm -f $(BOOTSTRAP)/terraform.tfstate $(BOOTSTRAP)/terraform.tfstate.backup && \
		echo ">> State migrated to s3://$(STATE_BUCKET)"; \
	fi

# The state bucket is destroyed by its own destroy, so state is pulled local
# first. Scoped to flightdeck's own state by construction (spec 5b): this can
# only ever destroy what this stack created.
destroy-bootstrap:
	$(TF) -chdir=$(BOOTSTRAP) init -input=false $(BACKEND_FLAGS)
	$(TF) -chdir=$(BOOTSTRAP) state pull > $(BOOTSTRAP)/terraform.tfstate
	$(TF) -chdir=$(BOOTSTRAP) init -input=false -backend=false -reconfigure
	$(TF) -chdir=$(BOOTSTRAP) destroy

# --- App onboarding ----------------------------------------------------------
# Scaffolds a new app repo from template-app/ as a sibling of this checkout
# and registers it in the apps list. Deliberately does NOT run gh, apply
# terraform, or push anything — those are separate, deliberate steps (see
# NEXT STEPS below): repo creation and infra applies are deliberate actions,
# scaffolding is the mechanical part.
new-app:
	@test -n "$(NAME)" || { echo "usage: make new-app NAME=<name>"; exit 1; }
	@echo "$(NAME)" | grep -Eq '^[a-z][a-z0-9-]{0,15}$$' || { \
		echo "error: NAME must match ^[a-z][a-z0-9-]{0,15}\$$ — lowercase," \
		     "start with a letter, hyphens ok, max 16 chars (dev stacks" \
		     "append \"-dev\", so this leaves headroom under the 32-char" \
		     "target-group name limit)"; \
		exit 1; \
	}
	@[ ! -e ../$(NAME) ] || { echo "error: ../$(NAME) already exists"; exit 1; }
	@! grep -q '"$(NAME)"' $(BOOTSTRAP)/variables.tf || { \
		echo "error: $(NAME) is already in the apps registry ($(BOOTSTRAP)/variables.tf)"; \
		exit 1; \
	}
	cp -R template-app ../$(NAME)
	yq -i '.name = "$(NAME)"' ../$(NAME)/app-manifest.yaml
	git -C ../$(NAME) init -b main
	git -C ../$(NAME) add -A
	git -C ../$(NAME) commit -m "flightdeck template"
	sed -i '' '/default[[:space:]]*=[[:space:]]*\[/ s/\]$$/, "$(NAME)"]/' $(BOOTSTRAP)/variables.tf
	$(TF) -chdir=$(BOOTSTRAP) fmt
	$(TF) -chdir=$(BOOTSTRAP) init -input=false -backend=false > /dev/null
	$(TF) -chdir=$(BOOTSTRAP) validate
	@echo ""
	@echo "Scaffolded ../$(NAME) and registered it in $(BOOTSTRAP)/variables.tf."
	@echo "NEXT STEPS (manual — repo creation and infra applies are deliberate"
	@echo "actions, scaffolding is the mechanical part):"
	@echo "  1) review the registry diff, then: make bootstrap   (creates IAM + dev/prod ECR for $(NAME))"
	@echo "  2) gh repo create $(NAME) --public --source ../$(NAME)"
	@echo "  3) gh variable set FLIGHTDECK_DEPLOY_ROLE_ARN --repo <owner>/$(NAME) --body \"arn:aws:iam::$(ACCOUNT_ID):role/flightdeck-deploy-$(NAME)\""
	@echo "  4) git -C ../$(NAME) push -u origin main   ->  https://$(NAME)-dev.$(APP_DOMAIN)"
