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
