PROJ=wblocks2
SRC=$(wildcard src/*.c)
DEP=$(wildcard src/*) quickjs

.PHONY: clean run

$(PROJ).exe: $(SRC) $(DEP)
	x86_64-w64-mingw32-gcc -std=c99 -O2 -Wall -Iquickjs/include -Lquickjs/lib/quickjs -o $@ $(SRC) -static -lgdi32 -lquickjs

quickjs:
	@echo 'Downloading quickjs...'
	curl -LO 'https://github.com/mengmo/QuickJS-Windows-Build/releases/download/2021-03-27/quickjs-2021-03-27-win64-all.zip'
	@echo 'Extracting...'
	unzip quickjs-2021-03-27-win64-all.zip -d quickjs
	rm quickjs-2021-03-27-win64-all.zip
	@echo 'OK.'

clean:
	rm -rf $(PROJ).exe quickjs

run: $(PROJ).exe
	./$(PROJ).exe
