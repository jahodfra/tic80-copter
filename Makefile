.PHONY: all run sprites cities data clean

BUILD_DIR=build
TIC_BIN=./tic80
CART=$(BUILD_DIR)/copter.tic
ETOPO=raw/etopo5/ETOPO5.DOS
PLACES=raw/naturalearth/ne_10m_populated_places_simple.dbf

all: $(CART)

run: $(CART)
	$(TIC_BIN) $(CART) -skip

# the cart: Lua sources + sprite sheet + world data in map banks 1..6
$(CART): cart/src/*.lua cart/sprites.gif $(BUILD_DIR)/world.bin tools/build_cart.py
	python3 tools/build_cart.py --src cart/src --sheet cart/sprites.gif \
		--bank-data $(BUILD_DIR)/world.bin --out $(BUILD_DIR)/copter

# terrain grid from NASA land cover + NOAA ETOPO5 elevation (takes ~1 minute)
$(BUILD_DIR)/world.bin: tools/build_world.py lcc_global_8192.tif $(ETOPO)
	python3 tools/build_world.py --out $@ --preview $(BUILD_DIR)/world.png

$(ETOPO):
	mkdir -p raw/etopo5
	curl -L -o $@ https://www.ngdc.noaa.gov/mgg/global/relief/ETOPO5/TOPO/ETOPO5/ETOPO5.DOS

$(PLACES):
	mkdir -p raw/naturalearth
	curl -L -o raw/naturalearth/places.zip https://naciscdn.org/naturalearth/10m/cultural/ne_10m_populated_places_simple.zip
	cd raw/naturalearth && unzip -o places.zip

# generated sources that are kept in git (run explicitly: they overwrite edits)
sprites:
	python3 tools/make_sprites.py cart/sprites.gif

cities: $(PLACES)
	python3 tools/build_cities.py $(PLACES)

clean:
	-rm -f $(CART) $(BUILD_DIR)/copter.lua $(BUILD_DIR)/world.bin $(BUILD_DIR)/world.png
