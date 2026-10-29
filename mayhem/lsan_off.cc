// Leak detection is off by default for every ASan target in this fleet (build-time, not runtime).
extern "C" int __lsan_is_turned_off() { return 1; }
