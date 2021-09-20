SHELL:=/bin/bash
# Parsing
# --------------------------------------------------------------------
# assume 1st argument passed is the main target, the
# rest are arguments to pass to the makefile generated 
# by cmake in the subdirectory
FIRST_ARG := $(firstword $(MAKECMDGOALS))
ARGS := $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))

ROOT_DIR := $(shell dirname "$(realpath $(lastword $(MAKEFILE_LIST)))")
BUILD_DIR := $(ROOT_DIR)/build/$(FIRST_ARG)

# we want to use ninja
#CMAKE_GENERATOR := Ninja
#CMAKE_ARGS := -G$(CMAKE_GENERATOR)
#CMAKE_ARGS += -DBOARD_ROOT=$(ROOT_DIR)
#CMAKE_ARGS += -DBOARD=nrf52840dongle_nrf52840
SIGN_KEY := $(ROOT_DIR)/mcuboot/root-rsa-2048.pem
SIGN_TOOL := $(ROOT_DIR)/mcuboot/scripts/imgtool.py

DFU_KEY := $(ROOT_DIR)/priv_dfu.pem
DFU_KEY_C := $(ROOT_DIR)/dfu_public_key.c

VERSION=$(if $(wildcard $(ROOT_DIR)/VERSION),$(shell cat $(ROOT_DIR)/VERSION), unknown)

COLOR_BLUE = \033[1;94m
NO_COLOR   = \033[m

# add new applications here
ALL_TARGETS := zephyr

define colorecho
echo -e '${COLOR_BLUE}${1} ${NO_COLOR}'
endef

.PHONY: pkg build sign flash mcuboot blinky_demo

Q:=@
ifneq ($(V),1)
ifneq ($(Q),)
.SILENT:
MAKEFLAGS += -s
endif
endif

flash sign pkg menuconfig:
	:

keygen:
	$(call colorecho,'Generating new key for mcuboot images:' $(SIGN_KEY))
	$(SIGN_TOOL) keygen -k $(SIGN_KEY) -t rsa-2048
	$(call colorecho,'Generating new key for DFU updates:' $(DFU_KEY))
	nrfutil keys generate $(DFU_KEY)
	nrfutil keys display --key pk --format code $(DFU_KEY) --out_file $(DFU_KEY_C)

--prebuild_cmake:
	$(call colorecho,'Target:' $(FIRST_ARG))
	$(eval BUILD_DIR := $(ROOT_DIR)/build/$(FIRST_ARG))

	mkdir -p $(BUILD_DIR)\
	&& cd $(BUILD_DIR) \
	&& cmake $(CMAKE_ARGS) $(ROOT_DIR)/$(FIRST_ARG)/$(firstword $(ARGS))

${ALL_TARGETS}: --prebuild_cmake

	if [[ "$(ARGS)" == *"menuconfig"* ]]; then\
		cd $(BUILD_DIR) && ninja menuconfig;\
	fi

	cd $(BUILD_DIR) && ninja

	if [[ "$(ARGS)" == *"sign"* ]]; then\
		$(call colorecho,Creating mcuboot compatible images);\
		$(call colorecho,'Signing with key:' $(SIGN_KEY));\
		cd $(BUILD_DIR) \
			&& $(SIGN_TOOL) sign \
				--key $(SIGN_KEY) \
				--header-size 0x200 \
				--pad-header \
				--align 8 \
				--version $(VERSION) \
				--slot-size 430080 \
				zephyr/zephyr.hex zephyr/signed.hex;\
		cd $(BUILD_DIR) \
			&& $(SIGN_TOOL) sign \
				--key $(SIGN_KEY) \
				--header-size 0x200 \
				--pad-header \
				--align 8 \
				--version $(VERSION) \
				--slot-size 430080 \
				zephyr/zephyr.bin zephyr/signed.bin;\
	fi

	if [[ "$(ARGS)" == *"pkg"* ]]; then\
		$(call colorecho,'Creating dfu package');\
		$(call colorecho,'Signing with key:' $(DFU_KEY));\
		cd $(BUILD_DIR) \
		&& nrfutil pkg generate --hw-version 52 --sd-req 0x00 \
		--application-version 0\
		--application signed.hex \
		--key-file $(DFU_KEY) \
		$(FIRST_ARG)_dfu_$(VERSION).zip;\
	fi

	if [[ "$(ARGS)" == *"flash"* ]]; then\
		cd $(BUILD_DIR) \
			&& nrfjprog -f NRF52 --program signed.hex --sectorerase;\
		cd $(BUILD_DIR) \
			&& nrfjprog -f NRF52 --verify signed.hex;\
		nrfjprog -r;\
	fi

mcuboot:
	$(call colorecho,'Building' $@)
	$(eval BUILD_DIR := $(ROOT_DIR)/build/$@)
	mkdir -p $(BUILD_DIR) \
		&& cd $(BUILD_DIR) \
		&& cmake $(CMAKE_ARGS) $(ROOT_DIR)/$@/boot/zephyr

	if [[ "$(ARGS)" == *"menuconfig"* ]]; then\
		cd $(BUILD_DIR) && ninja menuconfig;\
	fi

	cd $(BUILD_DIR) && ninja

	if [[ "$(ARGS)" == *"flash"* ]]; then\
		cd $(BUILD_DIR) \
			&& nrfjprog -f NRF52 --program zephyr/zephyr.hex --sectorerase;\
		cd $(BUILD_DIR) \
			&& nrfjprog -f NRF52 --verify zephyr/zephyr.hex;\
		nrfjprog -r;\
	fi

blinky:
	make mcuboot
	make zephyr samples/basic/blinky sign

	mergehex --merge $(ROOT_DIR)/build/mcuboot/zephyr/zephyr.hex \
		$(ROOT_DIR)/build/zephyr/zephyr/signed.hex \
		--output $(ROOT_DIR)/build/mcuboot_blinky_demo_signed.hex

	if [[ "$(ARGS)" == *"flash"* ]]; then\
		nrfjprog -f NRF52 --program $(ROOT_DIR)/build/mcuboot_blinky_demo_signed.hex --chiperase --log;\
		nrfjprog -f NRF52 --verify $(ROOT_DIR)/build/mcuboot_blinky_demo_signed.hex --log;\
		nrfjprog -r;\
	fi

mcuboot_demo:
	west build -b nrf52840dongle_nrf52840 -d build/mcuboot mcuboot/boot/zephyr
	nrfutil pkg generate --hw-version 52 --sd-req=0x00 \
		--application build/mcuboot/zephyr/zephyr.hex \
		--application-version 1 build/mcuboot.zip

	if [[ "$(ARGS)" == *"dfu"* ]]; then\
		nrfutil dfu usb-serial -pkg build/mcuboot.zip -p /dev/ttyACM0;\
	fi

blinky_demo:
	west build -b nrf52840dongle_nrf52840 -d build/blinky zephyr/samples/basic/blinky -- -DCONFIG_BOOTLOADER_MCUBOOT=y
	west sign -t imgtool --bin --no-hex -d build/blinky \
		-B build/blinky.signed.bin -- --key mcuboot/root-rsa-2048.pem

	if [[ "$(ARGS)" == *"dfu"* ]]; then\
		mcumgr --conntype=serial --connstring='dev=/dev/ttyACM0,baud=115200' \
			image upload -e build/blinky.signed.bin;\
		mcumgr --conntype=serial --connstring='dev=/dev/ttyACM0,baud=115200' reset;\
	fi

erase:
	nrfjprog --eraseall

reset:
	nrfjprog -r

clean:
	rm -rf $(ROOT_DIR)/build

list_targets:
	for targ in $(ALL_TARGETS); do echo $$targ; done

# Help / Error
# --------------------------------------------------------------------
# All other targets are handled here.
%:
	$(if $(filter $(FIRST_ARG),$@), \
	$(error $@ cannot be the first argument. \
	Use `make list_targets` to find all possible targets),@#)
