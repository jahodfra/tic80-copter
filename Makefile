.PHONY: all run sprites cities data clean

BUILD_DIR=build
TIC_BIN=./tic80
CART=$(BUILD_DIR)/copter.tic
ETOPO=raw/etopo5/ETOPO5.DOS
PLACES=raw/naturalearth/ne_10m_populated_places_simple.dbf
# NASA land cover map (Boston University / NASA GSFC, 2002). NASA retired the
# original server (eoimages.gsfc.nasa.gov); this is the Internet Archive copy.
LCC=lcc_global_8192.tif
LCC_URL=https://web.archive.org/web/20250331092120id_/https://eoimages.gsfc.nasa.gov/images/imagerecords/61000/61004/lcc_global_8192.tif
LCC_SHA256=d2cf9d64c00c8ad29e31229cbc18d022ab12763787b765bd1433841673f2a00c

all: $(CART)

run: $(CART)
	$(TIC_BIN) $(CART) -skip

# the cart: Lua sources + sprite sheet + world data in map banks 1..6
$(CART): cart/src/*.lua cart/sprites.gif $(BUILD_DIR)/world.bin tools/build_cart.py
	python3 tools/build_cart.py --src cart/src --sheet cart/sprites.gif \
		--bank-data $(BUILD_DIR)/world.bin --out $(BUILD_DIR)/copter

# terrain grid from NASA land cover + NOAA ETOPO5 elevation (takes ~1 minute)
$(BUILD_DIR)/world.bin: tools/build_world.py $(LCC) $(ETOPO)
	python3 tools/build_world.py --lcc $(LCC) --out $@ --preview $(BUILD_DIR)/world.png

# downloaded only when missing, and checked before use
$(LCC):
	curl -L -o $@.part $(LCC_URL)
	echo "$(LCC_SHA256)  $@.part" | sha256sum -c -
	mv $@.part $@

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
