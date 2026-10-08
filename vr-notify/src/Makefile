PKGS = openvr sdbus-c++ pangocairo librsvg-2.0 gdk-pixbuf-2.0 gl egl x11 uuid
CXXFLAGS ?= -O2
CXXFLAGS += -std=c++20 -Wall -Wextra $(shell pkg-config --cflags $(PKGS))
# gl, egl, x11 and uuid are for SteamVR's vrclient.so, which libopenvr_api loads: a Nix
# program's loader doesn't search the host's /usr/lib, but libraries already loaded count
LDLIBS = -Wl,--no-as-needed $(shell pkg-config --libs $(PKGS))
PREFIX ?= /usr/local

vr-notifyd: main.o render.o icons.o
	$(CXX) $(LDFLAGS) -o $@ $^ $(LDLIBS)

%.o: %.cpp render.h icons.h
	$(CXX) $(CXXFLAGS) -c -o $@ $<

install: vr-notifyd
	install -Dm755 vr-notifyd $(PREFIX)/bin/vr-notifyd

clean:
	rm -f vr-notifyd *.o

.PHONY: install clean
