# Built on the board (PYNQ-Z2, g++ 11, Cortex-A9 NEON): make -j2
CXX      ?= g++
CXXFLAGS ?= -O2 -g -std=c++17 -Wall -Wextra -Wno-unused-parameter \
            -mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard -ftree-vectorize -ffast-math
CPPFLAGS += -I/usr/include/xrt -I/usr/include/freetype2 -MMD -MP
LDLIBS   += -lxrt_coreutil -lfreetype -lpng -ljpeg -lpthread

SRCS := $(wildcard ../../src/ps_app/*.cpp)
OBJS := $(SRCS:../../src/ps_app/%.cpp=build/%.o)

echo_demo: $(OBJS)
	$(CXX) $(CXXFLAGS) -o $@ $^ $(LDLIBS)

build/%.o: ../../src/ps_app/%.cpp | build
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -c -o $@ $<

build:
	mkdir -p build

clean:
	rm -rf build echo_demo

-include $(OBJS:.o=.d)
.PHONY: clean
