IMAGE      ?= curse-dev:latest
BUILDER    ?= curse-dev
NODE_MAJOR ?= 24

.PHONY: builder build rebuild shell versions clean

## builder: create + bootstrap the dedicated buildx builder (idempotent)
builder:
	@docker buildx inspect $(BUILDER) >/dev/null 2>&1 \
	  || docker buildx create --name $(BUILDER) --driver docker-container --bootstrap
	@docker buildx inspect $(BUILDER) --bootstrap >/dev/null

## build: build the dev image and load it into the local Docker
build: builder
	docker buildx build \
	  --builder $(BUILDER) \
	  --build-arg NODE_MAJOR=$(NODE_MAJOR) \
	  --load \
	  -t $(IMAGE) .

## rebuild: same as build but ignore the cache
rebuild: builder
	docker buildx build --no-cache \
	  --builder $(BUILDER) \
	  --build-arg NODE_MAJOR=$(NODE_MAJOR) \
	  --load \
	  -t $(IMAGE) .

## shell: open an interactive shell in the dev image (cwd mounted at /work)
shell:
	docker run --rm -it -v "$(CURDIR)":/work $(IMAGE)

## versions: print bash/node/npm versions from the built image
versions:
	docker run --rm $(IMAGE) bash -lc 'bash --version | head -1; echo "node $$(node --version)"; echo "npm  $$(npm --version)"'

## clean: remove the builder and the image
clean:
	-docker buildx rm $(BUILDER)
	-docker image rm $(IMAGE)
