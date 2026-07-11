# flightdeck app-repo developer tool. GNU Make 3.81 compatible: no .ONESHELL,
# no ::=, no 4.x-only functions. Each recipe line is its own shell invocation;
# multi-step checks use a single line with backslash continuations so state
# (variables, exit-on-failure) carries across the steps of that check.
#
# `make preflight` mirrors the CI gates in .github/workflows/build-scan-push.yml
# and terraform-plan-apply.yml exactly, so a clean local run means CI is clean too.

MANIFEST := app-manifest.yaml
SCHEMA   := app-manifest.schema.json
IMAGE    := flightdeck-preflight:latest
CONTAINER := flightdeck-preflight-run

.PHONY: preflight run test check-tools validate-manifest build-image health-check scan

preflight: check-tools validate-manifest build-image health-check scan
	@echo "preflight clean — push to main to deploy"

# ---------------------------------------------------------------------------
# 1. Tool check
# ---------------------------------------------------------------------------

check-tools:
	@command -v docker >/dev/null 2>&1 || { echo "docker not found — install Docker Desktop → see docs/contract.md"; exit 1; }
	@command -v yq >/dev/null 2>&1 || { echo "yq not found — install: brew install yq → see docs/contract.md"; exit 1; }

# ---------------------------------------------------------------------------
# 2. Manifest validation (mirrors app-manifest.schema.json)
# ---------------------------------------------------------------------------

validate-manifest:
	@test -f $(MANIFEST) || { echo "$(MANIFEST) not found at repo root → see docs/contract.md"; exit 1; }
	@for k in $$(yq 'keys | .[]' $(MANIFEST)); do \
	  case " name port healthcheck cpu memory env " in \
	    *" $$k "*) : ;; \
	    *) if [ "$$k" = "image" ]; then \
	         echo "app-manifest.yaml has an 'image' field — CI supplies the image, never add one → see docs/contract.md"; \
	       else \
	         echo "app-manifest.yaml has unknown field '$$k' — only name, port, healthcheck, cpu, memory, env are allowed → see docs/contract.md"; \
	       fi; \
	       exit 1 ;; \
	  esac; \
	done
	@for f in name port healthcheck cpu memory; do \
	  v=$$(yq ".$$f" $(MANIFEST)); \
	  if [ "$$v" = "null" ]; then \
	    echo "app-manifest.yaml is missing required field '$$f' → see docs/contract.md"; \
	    exit 1; \
	  fi; \
	done
	@name=$$(yq '.name' $(MANIFEST)); \
	echo "$$name" | grep -Eq '^[a-z][a-z0-9-]{0,19}$$' || { \
	  echo "name '$$name' is invalid — must match ^[a-z][a-z0-9-]{0,19}$$ (lowercase, starts with a letter, max 20 chars) → see docs/contract.md"; \
	  exit 1; \
	}
	@port=$$(yq '.port' $(MANIFEST)); \
	case "$$port" in \
	  ''|*[!0-9]*) echo "port '$$port' is invalid — must be an integer → see docs/contract.md"; exit 1 ;; \
	esac; \
	if [ "$$port" -lt 1024 ] || [ "$$port" -gt 65535 ]; then \
	  echo "port $$port is out of range — must be 1024-65535, unprivileged only (contract rule 6) → see docs/contract.md"; \
	  exit 1; \
	fi
	@hc=$$(yq '.healthcheck' $(MANIFEST)); \
	case "$$hc" in \
	  /*) : ;; \
	  *) echo "healthcheck '$$hc' is invalid — must be an absolute path starting with '/' → see docs/contract.md"; exit 1 ;; \
	esac
	@cpu=$$(yq '.cpu' $(MANIFEST)); mem=$$(yq '.memory' $(MANIFEST)); \
	valid=0; \
	case "$$cpu" in \
	  256) case "$$mem" in 512|1024|2048) valid=1 ;; esac ;; \
	  512) case "$$mem" in 1024|2048|3072|4096) valid=1 ;; esac ;; \
	  1024) case "$$mem" in 2048|3072|4096|5120|6144|7168|8192) valid=1 ;; esac ;; \
	  *) valid=0 ;; \
	esac; \
	if [ "$$valid" -ne 1 ]; then \
	  echo "cpu=$$cpu / memory=$$mem is not a valid Fargate pair → see docs/contract.md"; \
	  exit 1; \
	fi
	@if [ "$$(yq '.env' $(MANIFEST))" != "null" ]; then \
	  for k in $$(yq '.env | keys | .[]' $(MANIFEST)); do \
	    t=$$(yq ".env.$$k | tag" $(MANIFEST)); \
	    if [ "$$t" != "!!str" ]; then \
	      echo "env.$$k must be a string value (found $$t) → see docs/contract.md"; \
	      exit 1; \
	    fi; \
	  done; \
	fi
	@echo "==> manifest OK"

# ---------------------------------------------------------------------------
# 3. Build (same --platform as the contract requires of every app)
# ---------------------------------------------------------------------------

build-image:
	@echo "==> building image"
	@docker build --platform linux/amd64 -t $(IMAGE) . || { echo "docker build failed → see docs/dockerfile.md"; exit 1; }

# ---------------------------------------------------------------------------
# 4. Run + healthcheck (30s budget, 2s poll — same contract CI/the platform enforce)
# ---------------------------------------------------------------------------

health-check:
	@port=$$(yq '.port' $(MANIFEST)); \
	hc=$$(yq '.healthcheck' $(MANIFEST)); \
	set --; \
	if [ "$$(yq '.env' $(MANIFEST))" != "null" ]; then \
	  for k in $$(yq '.env | keys | .[]' $(MANIFEST)); do \
	    v=$$(yq ".env.$$k" $(MANIFEST)); \
	    set -- "$$@" -e "$$k=$$v"; \
	  done; \
	fi; \
	docker rm -f $(CONTAINER) >/dev/null 2>&1 || true; \
	trap 'docker rm -f $(CONTAINER) >/dev/null 2>&1 || true' EXIT; \
	echo "==> starting container"; \
	docker run -d --name $(CONTAINER) -p $$port:$$port "$$@" $(IMAGE) >/dev/null || { \
	  echo "container failed to start → see docs/contract.md"; \
	  exit 1; \
	}; \
	elapsed=0; ok=0; code=000; \
	while [ $$elapsed -lt 30 ]; do \
	  code=$$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$$port$$hc" 2>/dev/null || echo 000); \
	  if [ "$$code" = "200" ]; then ok=1; break; fi; \
	  sleep 2; \
	  elapsed=$$((elapsed + 2)); \
	done; \
	if [ "$$ok" -ne 1 ]; then \
	  echo "healthcheck '$$hc' did not return 200 within 30s of container start (last status: $$code) — contract requires 200 within 30s → see docs/contract.md"; \
	  exit 1; \
	fi; \
	echo "==> healthcheck OK ($$code)"

# ---------------------------------------------------------------------------
# 5. Scan (optional locally; exact CI flags — see build-scan-push.yml and
#    terraform-plan-apply.yml)
# ---------------------------------------------------------------------------

scan:
	@if ! command -v trivy >/dev/null 2>&1; then \
	  echo "install trivy to run the same scan gates as CI: brew install trivy (skipping scan steps)"; \
	  exit 0; \
	fi; \
	echo "==> trivy image scan"; \
	trivy image --severity HIGH,CRITICAL --exit-code 1 --ignore-unfixed $(IMAGE) || { \
	  echo "trivy image scan found HIGH/CRITICAL vulnerabilities → see docs/pipeline.md"; \
	  exit 1; \
	}; \
	echo "==> trivy config scan"; \
	trivy config --severity HIGH,CRITICAL --exit-code 1 . || { \
	  echo "trivy config scan found HIGH/CRITICAL findings → see docs/pipeline.md"; \
	  exit 1; \
	}

# ---------------------------------------------------------------------------
# Manual poking
# ---------------------------------------------------------------------------

run: build-image
	@port=$$(yq '.port' $(MANIFEST)); \
	set --; \
	if [ "$$(yq '.env' $(MANIFEST))" != "null" ]; then \
	  for k in $$(yq '.env | keys | .[]' $(MANIFEST)); do \
	    v=$$(yq ".env.$$k" $(MANIFEST)); \
	    set -- "$$@" -e "$$k=$$v"; \
	  done; \
	fi; \
	echo "==> running on port $$port (ctrl-c to stop)"; \
	docker run --rm -p $$port:$$port "$$@" --name $(CONTAINER) $(IMAGE)

# Apps override this target with their own test command; the template has none.
test:
	@echo "no test command defined for this app — override the 'test' target in this Makefile if your app has one → see docs/example.md"
