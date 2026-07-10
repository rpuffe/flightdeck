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

.PHONY: fmt validate plan-bootstrap bootstrap destroy-bootstrap

fmt:
	$(TF) -chdir=$(BOOTSTRAP) fmt -recursive

validate:
	$(TF) -chdir=$(BOOTSTRAP) init -input=false -backend=false > /dev/null
	$(TF) -chdir=$(BOOTSTRAP) validate

plan-bootstrap:
	@if aws s3api head-bucket --bucket $(STATE_BUCKET) 2>/dev/null; then \
		$(TF) -chdir=$(BOOTSTRAP) init -input=false $(BACKEND_FLAGS); \
	else \
		$(TF) -chdir=$(BOOTSTRAP) init -input=false -backend=false; \
	fi
	$(TF) -chdir=$(BOOTSTRAP) plan

# First run: the state bucket is created by this very stack, so apply runs
# against local state, then state migrates into the bucket. Subsequent runs
# init against the bucket directly.
bootstrap:
	@if aws s3api head-bucket --bucket $(STATE_BUCKET) 2>/dev/null; then \
		$(TF) -chdir=$(BOOTSTRAP) init -input=false $(BACKEND_FLAGS) && \
		$(TF) -chdir=$(BOOTSTRAP) apply; \
	else \
		echo ">> First run: applying with local state, then migrating to S3" && \
		$(TF) -chdir=$(BOOTSTRAP) init -input=false -backend=false && \
		$(TF) -chdir=$(BOOTSTRAP) apply && \
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
