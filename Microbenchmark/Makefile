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
WEIGHTED_PHASE_TEST := $(BUILD_DIR)/tests/test_weighted_phase
PHASE_BOUNDARY_PROBE_TEST := $(BUILD_DIR)/tests/test_phase_boundary_probe

SRC := $(wildcard src/core/*.c) $(wildcard src/kernels/*.c)
OBJ := $(patsubst %.c,$(BUILD_DIR)/%.o,$(SRC))
TEST_OBJ := $(BUILD_DIR)/tests/test_weighted_phase.o \
	$(BUILD_DIR)/tests/test_phase_boundary_probe.o
DEP := $(OBJ:.o=.d) $(TEST_OBJ:.o=.d)

.PHONY: all clean run test test-weighted-phase test-phase-boundary-probe

all: $(TARGET)

$(TARGET): $(OBJ)
	$(CC) $(LDFLAGS) $^ -o $@ $(LDLIBS)

$(BUILD_DIR)/%.o: %.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -Iinclude -MMD -MP -c $< -o $@

run: $(TARGET)
	./$(TARGET) --mode bw --arena-size 64M --window-size 32M --duration-sec 2

test: test-weighted-phase test-phase-boundary-probe

test-weighted-phase: $(WEIGHTED_PHASE_TEST)
	./$(WEIGHTED_PHASE_TEST)

test-phase-boundary-probe: $(PHASE_BOUNDARY_PROBE_TEST)
	./$(PHASE_BOUNDARY_PROBE_TEST)

$(WEIGHTED_PHASE_TEST): $(BUILD_DIR)/tests/test_weighted_phase.o \
		$(BUILD_DIR)/src/core/config.o $(BUILD_DIR)/src/core/phase.o \
		$(BUILD_DIR)/src/kernels/mbench_skewed.o
	$(CC) $(LDFLAGS) $^ -o $@ $(LDLIBS)

$(PHASE_BOUNDARY_PROBE_TEST): $(BUILD_DIR)/tests/test_phase_boundary_probe.o \
		$(BUILD_DIR)/src/core/config.o $(BUILD_DIR)/src/core/phase.o \
		$(BUILD_DIR)/src/core/numa.o $(BUILD_DIR)/src/core/time.o
	$(CC) $(LDFLAGS) $^ -o $@ $(LDLIBS)

clean:
	rm -rf $(BUILD_DIR) $(TARGET)

-include $(DEP)
