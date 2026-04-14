.PHONY: start test-smoke test-remote

start:
	@if [ ! -f .env ]; then \
		echo "No .env file found — let's create one."; \
		printf "Public domain (e.g. packages.example.com): "; \
		read domain; \
		printf "Bearer token for POST /api/fetch (leave blank to generate): "; \
		read token; \
		if [ -z "$$token" ]; then \
			token=$$(head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 32); \
			echo "Generated token: $$token"; \
		fi; \
		printf "PACKBASE_DOMAIN=$$domain\nPACKBASE_TOKEN=$$token\n" > .env; \
		echo ".env created."; \
	fi
	docker compose up -d

test-smoke:
	@echo "Running smoke tests..."
	@bash test/smoke.sh

test-remote:
	@echo "Running remote clone test..."
	@bash test/remote.sh "$(PACKBASE_REMOTE_DOMAIN)" "$(or $(PACKBASE_REMOTE_REPO),hello)"
