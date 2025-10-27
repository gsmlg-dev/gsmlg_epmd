.PHONY: help certs clean-certs build up down logs shell-node1 shell-node2 shell-node3 shell-node4 clean

help:
	@echo "GSMLG EPMD TLS Auto-Mesh Example"
	@echo ""
	@echo "Usage:"
	@echo "  make certs        Generate certificates for all nodes"
	@echo "  make build        Build Docker images"
	@echo "  make up           Start all nodes with docker-compose"
	@echo "  make down         Stop all nodes"
	@echo "  make logs         Show logs from all nodes"
	@echo "  make shell-node1  Connect to node1 remote shell"
	@echo "  make shell-node2  Connect to node2 remote shell"
	@echo "  make shell-node3  Connect to node3 remote shell"
	@echo "  make shell-node4  Connect to node4 remote shell"
	@echo "  make clean        Remove build artifacts and containers"
	@echo "  make clean-certs  Remove generated certificates"

certs:
	@echo "Generating certificates..."
	../../tools/generate_certs.sh production node1 ./certs
	../../tools/generate_certs.sh production node2 ./certs
	../../tools/generate_certs.sh production node3 ./certs
	../../tools/generate_certs.sh staging node4 ./certs
	@echo ""
	@echo "✓ Certificates generated in ./certs/"

clean-certs:
	rm -rf certs/

build:
	docker-compose build

up:
	docker-compose up -d
	@echo ""
	@echo "Nodes started! Wait a few seconds for auto-mesh to form..."
	@echo ""
	@echo "Check connections:"
	@echo "  make shell-node1"

down:
	docker-compose down

logs:
	docker-compose logs -f

shell-node1:
	docker exec -it tls_node1 bin/gsmlg_epmd_test remote_console

shell-node2:
	docker exec -it tls_node2 bin/gsmlg_epmd_test remote_console

shell-node3:
	docker exec -it tls_node3 bin/gsmlg_epmd_test remote_console

shell-node4:
	docker exec -it tls_node4 bin/gsmlg_epmd_test remote_console

clean: down clean-certs
	docker-compose rm -f
	rm -rf _build
