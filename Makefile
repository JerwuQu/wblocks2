PROJ=wblocks2
SRC=$(wildcard src/*.cpp)
DEP=$(wildcard src/*) quickjs

.PHONY: clean clean-all run

DEBUGFLAG=
ifeq ($(DEBUG), 1)
	DEBUGFLAG=-DDEBUG
endif

$(PROJ).exe: $(SRC) $(DEP) wblocks.res
	x86_64-w64-mingw32-g++ $(DEBUGFLAG) -std=c++20 -O2 -Wall -Wl,-subsystem,windows -Iquickjs/include -Lquickjs/lib/quickjs -o $@ $(SRC) wblocks.res -static -lstdc++ -lgdi32 -lquickjs -pthread

wblocks.res:
	x86_64-w64-mingw32-windres wblocks.rc -O coff -o wblocks.res

quickjs:
	@echo 'Downloading quickjs...'
	curl -LO 'https://github.com/mengmo/QuickJS-Windows-Build/releases/download/2021-03-27/quickjs-2021-03-27-win64-all.zip'
	@echo 'Extracting...'
	unzip quickjs-2021-03-27-win64-all.zip -d quickjs
	rm quickjs-2021-03-27-win64-all.zip
	@echo 'OK.'

clean:
	rm -f $(PROJ).exe wblocks.res

clean-all: clean
	rm -rf quickjs

run: $(PROJ).exe
	./$(PROJ).exe
