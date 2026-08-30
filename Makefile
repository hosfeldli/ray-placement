PROJECT_DIRECTORY := $(CURDIR)
SCRATCH_DIRECTORY := $(PROJECT_DIRECTORY)/.build
MODULE_CACHE_DIRECTORY := $(SCRATCH_DIRECTORY)/module-cache
SWIFT_ENV := CLANG_MODULE_CACHE_PATH=$(MODULE_CACHE_DIRECTORY) SWIFTPM_MODULECACHE_OVERRIDE=$(MODULE_CACHE_DIRECTORY)

.PHONY: build test package verify run clean

build:
	$(SWIFT_ENV) swift build --disable-sandbox --scratch-path "$(SCRATCH_DIRECTORY)"

test:
	$(SWIFT_ENV) swift test --disable-sandbox --scratch-path "$(SCRATCH_DIRECTORY)"

package:
	./scripts/package_liamflow_app.sh

verify:
	./scripts/verify_liamflow_app.sh

run: package
	open "$(PROJECT_DIRECTORY)/build/Lima.app"

clean:
	$(SWIFT_ENV) swift package --disable-sandbox --scratch-path "$(SCRATCH_DIRECTORY)" clean
