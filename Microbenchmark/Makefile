CC := gcc
PKG_CONFIG ?= pkg-config

NUMA_CFLAGS := $(shell $(PKG_CONFIG) --cflags numa 2>/dev/null)
NUMA_LIBS := $(shell $(PKG_CONFIG) --libs numa 2>/dev/null)

CFLAGS := -O3 -g -std=gnu11 -Wall -Wextra -Wpedantic -Wshadow -Wformat=2 \
	-Wstrict-prototypes -Wmissing-prototypes -march=native \
	-mtune=native -fno-omit-frame-pointer -pthread $(NUMA_CFLAGS)
LDFLAGS := -pthread
LDLIBS := $(NUMA_LIBS) -lm

BUILD_DIR := build
TARGET := mbench

SRC := $(wildcard src/core/*.c) $(wildcard src/kernels/*.c)
OBJ := $(patsubst %.c,$(BUILD_DIR)/%.o,$(SRC))
DEP := $(OBJ:.o=.d)

.PHONY: all clean run

all: $(TARGET)

$(TARGET): $(OBJ)
	$(CC) $(LDFLAGS) $^ -o $@ $(LDLIBS)

$(BUILD_DIR)/%.o: %.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -Iinclude -MMD -MP -c $< -o $@

run: $(TARGET)
	./$(TARGET) --mode bw --arena-size 64M --window-size 32M --duration-sec 2

clean:
	rm -rf $(BUILD_DIR) $(TARGET)

-include $(DEP)
