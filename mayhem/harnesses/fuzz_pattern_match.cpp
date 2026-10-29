#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <fuzzer/FuzzedDataProvider.h>

extern "C" int pattern_match(char *string, char *patterns, int found);

extern "C" int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	FuzzedDataProvider provider(data, size);

	char *string = strdup(provider.ConsumeRandomLengthString().c_str());
	char *patterns = strdup(provider.ConsumeRandomLengthString().c_str());

	pattern_match(string, patterns, 0);

	free(string);
	free(patterns);

	return 0;
}
