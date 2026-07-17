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
REPO_URL := https://github.com/rpuffe/flightdeck

.PHONY: preflight run test check-tools validate-manifest build-image health-check scan upgrade

preflight: check-tools validate-manifest build-image health-check scan
	@echo "preflight clean — push to main to deploy"

# ---------------------------------------------------------------------------
# 1. Tool check
# ---------------------------------------------------------------------------

check-tools:
	@command -v docker >/dev/null 2>&1 || { echo "docker not found — install Docker Desktop → see docs/contract.md"; exit 1; }
	@command -v yq >/dev/null 2>&1 || { echo "yq not found — install: brew install yq → see docs/contract.md"; exit 1; }
	@pinned=$$(grep -o 'ref=v[0-9.]*' main.tf | sed 's/^ref=//'); \
	if [ -f .flightdeck-version ]; then \
	  contract=$$(cat .flightdeck-version); \
	  if [ -n "$$pinned" ] && [ "$$contract" != "$$pinned" ]; then \
	    echo "WARNING: contract files are $$contract but main.tf pins $$pinned — run make upgrade"; \
	  fi; \
	else \
	  echo "note: no .flightdeck-version (pre-v0.5.0 contract) — run make upgrade to refresh"; \
	fi

# ---------------------------------------------------------------------------
# 2. Manifest validation (mirrors app-manifest.schema.json)
# ---------------------------------------------------------------------------

validate-manifest:
	@test -f $(MANIFEST) || { echo "$(MANIFEST) not found at repo root → see docs/contract.md"; exit 1; }
	@for k in $$(yq 'keys | .[]' $(MANIFEST)); do \
	  case " name port healthcheck cpu memory env storage auth " in \
	    *" $$k "*) : ;; \
	    *) if [ "$$k" = "image" ]; then \
	         echo "app-manifest.yaml has an 'image' field — CI supplies the image, never add one → see docs/contract.md"; \
	       else \
	         echo "app-manifest.yaml has unknown field '$$k' — only name, port, healthcheck, cpu, memory, env, storage, auth are allowed → see docs/contract.md"; \
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
	echo "$$name" | grep -Eq '^[a-z][a-z0-9-]{0,15}$$' || { \
	  echo "name '$$name' is invalid — must match ^[a-z][a-z0-9-]{0,15}$$ (lowercase, starts with a letter, max 16 chars — dev stacks append \"-dev\", so this leaves room under the 32-char target-group name limit) → see docs/contract.md"; \
	  exit 1; \
	}; \
	if [ "$$name" = "wake" ]; then \
	  echo "name 'wake' is reserved for the platform scaler endpoint — choose a different name → see docs/contract.md"; \
	  exit 1; \
	fi
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
	    case "$$k" in \
	      STORAGE_BUCKET) \
	        echo "env.STORAGE_BUCKET is reserved — the platform injects it when storage: s3 is set, don't define it yourself → see docs/contract.md"; \
	        exit 1 ;; \
	      COGNITO_USER_POOL_ID|COGNITO_CLIENT_ID|COGNITO_DOMAIN|COGNITO_ISSUER) \
	        echo "env.$$k is reserved — the platform injects it when auth: cognito is set, don't define it yourself → see docs/contract.md"; \
	        exit 1 ;; \
	    esac; \
	    t=$$(yq ".env.$$k | tag" $(MANIFEST)); \
	    if [ "$$t" != "!!str" ]; then \
	      echo "env.$$k must be a string value (found $$t) → see docs/contract.md"; \
	      exit 1; \
	    fi; \
	  done; \
	fi
	@if [ "$$(yq '.storage' $(MANIFEST))" != "null" ]; then \
	  storage=$$(yq '.storage' $(MANIFEST)); \
	  if [ "$$storage" != "s3" ]; then \
	    echo "storage '$$storage' is invalid — only 's3' is supported → see docs/contract.md"; \
	    exit 1; \
	  fi; \
	fi
	@if [ "$$(yq '.auth' $(MANIFEST))" != "null" ]; then \
	  auth=$$(yq '.auth' $(MANIFEST)); \
	  if [ "$$auth" != "cognito" ]; then \
	    echo "auth '$$auth' is invalid — only 'cognito' is supported → see docs/contract.md"; \
	    exit 1; \
	  fi; \
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

# App test logic lives in test.sh, NOT here — the Makefile is 100%
# platform-owned and whole-file replaceable by `make upgrade`.
test:
	@if [ -f test.sh ]; then \
	  sh ./test.sh; \
	else \
	  echo "no test.sh found for this app — create test.sh at the repo root with your test command → see docs/example.md"; \
	fi

# ---------------------------------------------------------------------------
# 6. Upgrade — refresh platform-owned files to a flightdeck release
# ---------------------------------------------------------------------------
#
# make upgrade            — upgrades to the latest published vX.Y.Z tag
# make upgrade TAG=v0.4.0 — upgrades (or downgrades) to a specific tag
#
# Replaces the platform-owned file set below from the tagged release and
# never touches app-owned files (app-manifest.yaml, Dockerfile, test.sh,
# source code). Refuses to run over uncommitted changes under those paths.
# Never commits — review with git diff/git status and commit yourself.

upgrade:
	@set -e; \
	tag="$(TAG)"; \
	if [ -z "$$tag" ]; then \
	  echo "==> no TAG given, resolving latest release from $(REPO_URL)"; \
	  tag=$$(git ls-remote --tags $(REPO_URL).git 'v*' | grep -v '\^{}' | awk -F/ '{print $$NF}' | sort -V | tail -1); \
	  if [ -z "$$tag" ]; then \
	    echo "could not resolve latest tag from $(REPO_URL) — pass TAG=vX.Y.Z explicitly"; \
	    exit 1; \
	  fi; \
	fi; \
	echo "==> upgrading platform-owned files to $$tag"; \
	echo "$$tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$$' || { echo "TAG must match vX.Y.Z"; exit 1; }; \
	for p in AGENTS.md CLAUDE.md docs app-manifest.schema.json main.tf .github/workflows/ci.yml .flightdeck-version .flightdeck-provenance Makefile; do \
	  if [ -n "$$(git status --porcelain -- "$$p" 2>/dev/null)" ]; then \
	    echo "uncommitted changes under platform-owned paths — commit or stash them first (do NOT discard; make upgrade never destroys work)"; \
	    exit 1; \
	  fi; \
	done; \
	if [ -f .flightdeck-version ]; then prev=$$(cat .flightdeck-version); else prev="pre-v0.5.0"; fi; \
	tmpdir=$$(mktemp -d); \
	trap 'rm -rf "$$tmpdir"' EXIT; \
	resolve_tag() { \
	  git ls-remote --tags "$(REPO_URL).git" "refs/tags/$$tag" "refs/tags/$$tag^{}" | \
	    awk -v direct="refs/tags/$$tag" -v peeled="refs/tags/$$tag^{}" '$$2 == direct { d=$$1 } $$2 == peeled { p=$$1 } END { print (p != "" ? p : d) }'; \
	}; \
	commit=$$(resolve_tag); \
	echo "$$commit" | grep -Eq '^[0-9a-f]{40}$$' || { echo "could not resolve $$tag to an immutable commit"; exit 1; }; \
	echo "==> fetching $$tag at immutable commit $$commit"; \
	curl -fsSL "$(REPO_URL)/archive/$$commit.tar.gz" -o "$$tmpdir/release.tar.gz" || { \
	  echo "failed to fetch $$tag from $(REPO_URL) — check the tag exists and network is reachable"; \
	  exit 1; \
	}; \
	if command -v sha256sum >/dev/null 2>&1; then \
	  hash_output=$$(sha256sum "$$tmpdir/release.tar.gz") || { echo "failed to calculate release archive SHA-256"; exit 1; }; \
	elif command -v shasum >/dev/null 2>&1; then \
	  hash_output=$$(shasum -a 256 "$$tmpdir/release.tar.gz") || { echo "failed to calculate release archive SHA-256"; exit 1; }; \
	else \
	  echo "cannot verify release archive: sha256sum or shasum is required"; \
	  exit 1; \
	fi; \
	archive_sha=$$(printf '%s\n' "$$hash_output" | awk '{print $$1}'); \
	echo "$$archive_sha" | grep -Eq '^[0-9a-fA-F]{64}$$' || { echo "release archive returned an invalid SHA-256"; exit 1; }; \
	tar -xzf "$$tmpdir/release.tar.gz" -C "$$tmpdir" || { echo "failed to extract $$tag archive"; exit 1; }; \
	src=$$(find "$$tmpdir" -type d -path '*/template-app' | head -1); \
	if [ -z "$$src" ]; then \
	  echo "could not find template-app/ inside $$tag archive"; \
	  exit 1; \
	fi; \
	for required in AGENTS.md CLAUDE.md app-manifest.schema.json main.tf Makefile .github/workflows/ci.yml; do \
	  if [ ! -f "$$src/$$required" ]; then \
	    echo "malformed release archive: missing template-app/$$required"; \
	    echo "no files were replaced"; \
	    exit 1; \
	  fi; \
	done; \
	if [ ! -d "$$src/docs" ]; then \
	  echo "malformed release archive: missing template-app/docs"; \
	  echo "no files were replaced"; \
	  exit 1; \
	fi; \
	if [ -f "$$src/.flightdeck-version" ]; then \
	  embedded=$$(cat "$$src/.flightdeck-version"); \
	else \
	  embedded=""; \
	fi; \
	if [ -n "$$embedded" ] && [ "$$embedded" != "$$tag" ]; then \
	  echo "release marker mismatch: requested $$tag but immutable archive records $${embedded:-<missing>}"; \
	  echo "no files were replaced"; \
	  exit 1; \
	fi; \
	if [ -z "$$embedded" ] && ! awk -v tag="$$tag" 'BEGIN { sub(/^v/, "", tag); split(tag, v, "."); exit ! (v[1] + 0 == 0 && v[2] + 0 < 5) }'; then \
	  echo "release marker missing from $$tag archive (only releases before v0.5.0 may omit it)"; \
	  echo "no files were replaced"; \
	  exit 1; \
	fi; \
	verified_commit=$$(resolve_tag); \
	if [ "$$verified_commit" != "$$commit" ]; then \
	  echo "release provenance changed while fetching $$tag ($$commit -> $${verified_commit:-unresolved})"; \
	  echo "no files were replaced"; \
	  exit 1; \
	fi; \
	if [ -f "$$src/app-manifest.schema.json" ] && [ -f $(MANIFEST) ]; then \
	  allowed=" $$(yq '.properties | keys | .[]' "$$src/app-manifest.schema.json" | tr -d '"' | tr '\n' ' ')"; \
	  for k in $$(yq 'keys | .[]' $(MANIFEST)); do \
	    case "$$allowed" in \
	      *" $$k "*) : ;; \
	      *) echo "WARNING: your manifest uses '$$k' which $$tag's schema does not define — preflight will fail until you remove it or pick a newer tag" ;; \
	    esac; \
	  done; \
	fi; \
	cp -f "$$src/AGENTS.md" AGENTS.md; \
	cp -f "$$src/CLAUDE.md" CLAUDE.md; \
	rm -rf docs && cp -R "$$src/docs" docs; \
	cp -f "$$src/app-manifest.schema.json" app-manifest.schema.json; \
	cp -f "$$src/main.tf" main.tf; \
	mkdir -p .github/workflows && cp -f "$$src/.github/workflows/ci.yml" .github/workflows/ci.yml; \
	if [ -f "$$src/.flightdeck-version" ]; then \
	  cp -f "$$src/.flightdeck-version" .flightdeck-version; \
	else \
	  echo "$$tag" > .flightdeck-version; \
	fi; \
	printf 'tag=%s\ncommit=%s\narchive_sha256=%s\n' "$$tag" "$$commit" "$$archive_sha" > .flightdeck-provenance; \
	cp -f "$$src/Makefile" Makefile; \
	echo "==> upgraded: $$prev -> $$tag"; \
	echo "verified provenance: commit=$$commit archive_sha256=$$archive_sha"; \
	echo "files replaced: AGENTS.md CLAUDE.md docs app-manifest.schema.json main.tf .github/workflows/ci.yml .flightdeck-version .flightdeck-provenance Makefile"; \
	echo "review with: git diff && git status, then commit. make upgrade never commits."
