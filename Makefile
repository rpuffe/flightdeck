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

.PHONY: fmt validate plan-bootstrap bootstrap destroy-bootstrap \
        plan-hello deploy-hello destroy-hello \
        ps stop start stop-all start-all \
        new-app

# --- Service operations ------------------------------------------------------
# Scale operations are deliberate drift: terraform state keeps desired_count=1,
# so the NEXT DEPLOY of a service restores it. Cheap overnight off-switch, not
# a permanent setting.

ps:
	@aws ecs list-services --cluster $(CLUSTER) --query 'serviceArns' --output text | tr '\t' '\n' | awk -F/ '{print $$NF}' | sort | while read s; do \
	  [ -n "$$s" ] || continue; \
	  aws ecs describe-services --cluster $(CLUSTER) --services $$s \
	    --query 'services[0].[serviceName,desiredCount,runningCount]' --output text | \
	  awk '{printf "%-20s desired=%s running=%s  https://%s.$(APP_DOMAIN)\n", $$1, $$2, $$3, $$1}'; \
	done

stop:
	@test -n "$(SVC)" || { echo "usage: make stop SVC=<service>   (make ps lists them)"; exit 1; }
	@aws ecs update-service --cluster $(CLUSTER) --service $(SVC) --desired-count 0 \
	  --query 'service.[serviceName,desiredCount]' --output text | awk '{print $$1" -> desired="$$2}'
	@echo "note: next deploy of $(SVC) restores desired=1 (terraform owns that value)"

start:
	@test -n "$(SVC)" || { echo "usage: make start SVC=<service>   (make ps lists them)"; exit 1; }
	@aws ecs update-service --cluster $(CLUSTER) --service $(SVC) --desired-count 1 \
	  --query 'service.[serviceName,desiredCount]' --output text | awk '{print $$1" -> desired="$$2}'

stop-all:
	@aws ecs list-services --cluster $(CLUSTER) --query 'serviceArns' --output text | tr '\t' '\n' | awk -F/ '{print $$NF}' | while read s; do \
	  [ -n "$$s" ] || continue; \
	  aws ecs update-service --cluster $(CLUSTER) --service $$s --desired-count 0 --query 'service.serviceName' --output text | awk '{print $$1" -> desired=0"}'; \
	done
	@echo "note: any service's next deploy restores it (terraform owns desired_count)"

start-all:
	@aws ecs list-services --cluster $(CLUSTER) --query 'serviceArns' --output text | tr '\t' '\n' | awk -F/ '{print $$NF}' | while read s; do \
	  [ -n "$$s" ] || continue; \
	  aws ecs update-service --cluster $(CLUSTER) --service $$s --desired-count 1 --query 'service.serviceName' --output text | awk '{print $$1" -> desired=1"}'; \
	done

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
	@echo "  1) review the registry diff, then: make bootstrap   (creates the ECR repo for $(NAME))"
	@echo "  2) gh repo create $(NAME) --public --source ../$(NAME)"
	@echo "  3) gh variable set FLIGHTDECK_DEPLOY_ROLE_ARN --repo <owner>/$(NAME) --body \"\$$(terraform -chdir=bootstrap output -raw deploy_role_arn)\""
	@echo "  4) git -C ../$(NAME) push -u origin main   ->  https://$(NAME)-dev.$(APP_DOMAIN)"
