.PHONY: build style clean all

BUILD_DIR=build

objects=$(BUILD_DIR)/copter.tic $(BUILD_DIR)/topomap.map $(BUILD_DIR)/topomap.tiles
TIC_BIN=./tic80

all: build run

build: $(objects)
	mkdir -p $(BUILD_DIR)
run:
	$(TIC_BIN) $(BUILD_DIR)/copter.tic -skip

style:
	luastyle -i copter.lua
        
$(BUILD_DIR)/topomap.map $(BUILD_DIR)/topomap.tiles: topomap.png prepare_map.py
	python3 -m prepare_map topomap.png $(BUILD_DIR)/topomap


$(BUILD_DIR)/copter.tic: copter.lua $(BUILD_DIR)/topomap.map $(BUILD_DIR)/topomap.tiles sprites.gif
	python3 -m make_cartridge \
	--code=copter.lua \
	--map=$(BUILD_DIR)/topomap.map \
	--tiles=$(BUILD_DIR)/topomap.tiles \
	--sprites=sprites.gif \
	-o $(BUILD_DIR)/copter.tic
  
clean:
	-rm $(objects)
