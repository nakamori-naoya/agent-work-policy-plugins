# 完了判定の検証。作業場所ごとに compose の project 名を分けて起動する。
PROJECT ?= shop-$(notdir $(CURDIR))
DB_PORT ?= 5432

verify:
	DB_PORT=$(DB_PORT) docker compose -p $(PROJECT) -f compose.yml up -d --wait db
	DB_PORT=$(DB_PORT) python3 -m unittest discover -s tests
	./tools/check-schema.sh
	docker compose -p $(PROJECT) -f compose.yml down -v
