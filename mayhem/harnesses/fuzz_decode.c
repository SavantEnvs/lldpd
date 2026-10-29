/* One libFuzzer harness per lldpd frame decoder; the decoder is chosen at compile time with
 * -DDECODER=<lldp|cdp|sonmp|edp>_decode. Mirrors upstream tests/fuzz_*.c, but rejects with -1. */
#include "../../src/daemon/lldpd.h"

#ifndef DECODER
#  error "compile with -DDECODER=<proto>_decode"
#endif

#define kMinInputLength 5
#define kMaxInputLength 2048

static void
donothing(int pri, const char *msg)
{
}

int
LLVMFuzzerTestOneInput(const uint8_t *Data, size_t Size)
{
	if (Size < kMinInputLength || Size > kMaxInputLength) return -1;

	struct lldpd_chassis *nchassis = NULL;
	struct lldpd_port *nport = NULL;
	struct lldpd_hardware hardware;

	memset(&hardware, 0, sizeof(hardware));
	hardware.h_mtu = 1500;
	strlcpy(hardware.h_ifname, "fuzz", sizeof(hardware.h_ifname));
	log_register(donothing);

	DECODER(NULL, (char *)Data, Size, &hardware, &nchassis, &nport);

	if (nport) {
		lldpd_port_cleanup(nport, 1);
		free(nport);
	}
	if (nchassis) lldpd_chassis_cleanup(nchassis, 1);
	return 0;
}
