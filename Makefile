# Build the Hadron sway-desktop image and a bootable installer ISO.
#
#   make image        # build the desktop OCI image
#   make iso          # wrap with the Kairos init layer + build the ISO
#   make              # both (image, then iso)
#   make clean        # remove build artifacts
#
# Knobs (override on the command line):
#   make GPU=full FIRMWARE=true          # hardware GL + real-hardware firmware
#   make IMAGE=sway-desktop:hw            # change the image tag
#   make BASE_IMAGE=ghcr.io/...:vX        # pin a different Hadron base

IMAGE        ?= sway-desktop:dev
INIT_IMAGE   ?= sway-desktop-init:dev
BASE_IMAGE   ?= ghcr.io/kairos-io/hadron:main
AURORA_IMAGE ?= quay.io/kairos/auroraboot:v0.21.0-alpha.4
KAIROS_DOCKERFILE_URL := https://raw.githubusercontent.com/kairos-io/kairos/master/images/Dockerfile

WORK    := build/sway-desktop
ISO_DIR := $(WORK)/iso

# Optional build args, only passed when set (otherwise the Dockerfile defaults
# apply: GPU=vm, FIRMWARE=false).
BUILD_ARGS := --build-arg BASE_IMAGE=$(BASE_IMAGE)
ifdef GPU
BUILD_ARGS += --build-arg GPU=$(GPU)
endif
ifdef FIRMWARE
BUILD_ARGS += --build-arg FIRMWARE=$(FIRMWARE)
endif

export DOCKER_BUILDKIT := 1

.PHONY: all image iso clean

all: iso

# The desktop OCI image.
image:
	docker build $(BUILD_ARGS) -t $(IMAGE) .

# Wrap the image with the Kairos init layer, then build the installer ISO with
# AuroraBoot (needs the Docker socket to read the local image).
iso: image
	mkdir -p $(ISO_DIR)
	curl -sSL $(KAIROS_DOCKERFILE_URL) -o $(WORK)/Dockerfile.kairos
	docker build -t $(INIT_IMAGE) -f $(WORK)/Dockerfile.kairos \
	  --build-arg BASE_IMAGE=$(IMAGE) \
	  --build-arg VERSION=v0.0.0 \
	  --build-arg TRUSTED_BOOT=false \
	  --build-arg MODEL=generic \
	  --build-arg FIPS=no-fips \
	  $(WORK)
	rm -f $(ISO_DIR)/*.iso
	docker run --rm --privileged \
	  -v /var/run/docker.sock:/var/run/docker.sock \
	  -v $(CURDIR)/$(ISO_DIR):/output \
	  $(AURORA_IMAGE) build-iso --output /output/ docker:$(INIT_IMAGE)
	@echo "ISO: $$(ls -t $(ISO_DIR)/*.iso | head -1)"

clean:
	rm -rf $(WORK)
