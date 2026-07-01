docker network create rsk-simulation-net
docker compose -f docker-compose.tools.yml down -v
docker compose -f docker-compose.rskj.yml down -v
docker compose -f docker-compose.tools.yml up -d  
docker compose -f docker-compose.rskj.yml up -d
