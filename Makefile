.PHONY: start deploy test-smoke test-remote clean update logs status

push:
	@git config credential.helper 'cache --timeout=3600'
	@git add .
	@git commit -m "Update" || true
	@git push

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

deploy: push
	@if [ ! -f .hosts ]; then \
		echo "No .hosts file found."; \
		echo "Create .hosts with one entry per line:  host=<h> user=<u> password=<p> pwd=<dir>"; \
		exit 1; \
	fi
	@while IFS= read -r line || [ -n "$$line" ]; do \
		case "$$line" in ''|\#*) continue ;; esac; \
		H=$$(echo "$$line" | sed 's/.*host=\([^ ]*\).*/\1/'); \
		U=$$(echo "$$line" | sed 's/.*user=\([^ ]*\).*/\1/'); \
		P=$$(echo "$$line" | sed 's/.*password=\([^ ]*\).*/\1/'); \
		D=$$(echo "$$line" | sed 's/.*pwd=\([^ ]*\).*/\1/'); \
		echo "→ $$U@$$H:$$D"; \
		sshpass -p "$$P" ssh -o StrictHostKeyChecking=no "$$U@$$H" "cd '$$D' && make update"; \
	done < .hosts

update:
	@echo "Pulling latest changes..."
	@git pull
	@echo "Using RELEASE_ID:"
	@cat src/RELEASE_ID
	@echo "Building packbase..."
	@docker compose build packbase
	@echo "Restarting packbase..."
	@docker compose up -d packbase
	@echo "Removing cached git clones (keeping tarballs)..."
	@docker compose exec -T packbase rm -rf /data/git || true
	@echo "Showing logs..."
	@docker compose logs --tail=20 packbase

logs:
	@docker compose logs -f packbase

status:
	@docker compose ps
	@echo ""
	@echo "API info:"
	@curl -s "$(PACKBASE_DOMAIN)/api/info" 2>/dev/null || echo "Cannot reach server"

clean:
	@echo "Cleaning Docker resources..."
	@docker compose down --remove-orphans 2>/dev/null || true
	@docker system prune -f --filter "label=com.docker.compose.project" 2>/dev/null || true
	@echo "Done."

clean-all:
	@echo "Deep cleaning (including volumes)..."
	@docker compose down -v --remove-orphans 2>/dev/null || true
	@docker system prune -af 2>/dev/null || true
	@echo "Done."

test-smoke:
	@echo "Running smoke tests..."
	@bash test/smoke.sh

test-remote:
	@echo "Running remote clone test..."
	@bash test/remote.sh "$(PACKBASE_REMOTE_DOMAIN)" "$(or $(PACKBASE_REMOTE_REPO),hello)" "$(PACKBASE_EXPECTED_RELEASE)"
