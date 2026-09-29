/*
 * dfu-send — pomme boot helper: send a payload image into Apple (pwned) DFU.
 *
 * EXPERIMENTAL: this program has never been run against real hardware in the
 * pomme project (builds-not-boots, docs/pipeline-conventions.md). The DFU
 * protocol below is the standard USB DFU 1.1 class download sequence used by
 * Apple's bootROM (same requests gaster itself drives — see upstream/gaster
 * gaster.c: DFU_CLR_STATUS / DFU_DNLOAD / DFU_GETSTATUS control requests on
 * interface 0 of VID 0x05AC PID 0x1227).
 *
 * Role in the chain:
 *   gaster pwn        -> device is in pwned DFU, still enumerating as
 *                        VID 0x05AC PID 0x1227 (gaster waits on exactly this
 *                        VID/PID: "[libusb] Waiting for the USB handle with
 *                        VID: 0x5AC, PID: 0x1227")
 *   dfu-send Pongo.bin -> DFU_DNLOAD the pongoOS payload; the pwned bootROM
 *                        executes it; pongoOS re-enumerates as VID 0x05AC
 *                        PID 0x4141 (upstream/pongoOS-palera1n
 *                        src/drivers/usb/synopsys_otg.c:143, .idProduct = 0x4141)
 *   load-linux         -> (Sandcastle loader) send DTB + kernel, run fdt/bootl
 *
 * Usage:
 *   dfu-send <payload.bin> [--pid 0x1227] [--wait-pid 0x4141] [--timeout 60]
 *
 * Exit codes: 0 = payload sent (and --wait-pid seen if requested);
 *             nonzero = any failure, with the step that failed printed.
 *
 * pomme is MIT-licensed build glue; this file is written for pomme (not a
 * copy of any upstream source).
 */

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <libusb-1.0/libusb.h>

#define APPLE_VID 0x05ac
#define DFU_DNLOAD 1     /* bmRequestType 0x21, host->device, payload out   */
#define DFU_GETSTATUS 3  /* bmRequestType 0xA1, 6-byte status               */
#define CHUNK_SZ 0x800   /* conservative DFU block size (idevicerestore-style) */

static unsigned long parse_u32(const char *s)
{
	return strtoul(s, NULL, 0);
}

static int find_device(unsigned vid, unsigned pid, libusb_device_handle **out)
{
	libusb_device **devs;
	ssize_t n = libusb_get_device_list(NULL, &devs);
	if (n < 0)
		return n;
	*out = NULL;
	for (ssize_t i = 0; i < n; i++) {
		struct libusb_device_descriptor d;
		if (libusb_get_device_descriptor(devs[i], &d) != 0)
			continue;
		if (d.idVendor == vid && d.idProduct == pid) {
			libusb_device_handle *h = NULL;
			int rc = libusb_open(devs[i], &h);
			if (rc != LIBUSB_SUCCESS) {
				fprintf(stderr, "dfu-send: libusb_open failed: %s\n",
					libusb_error_name(rc));
				continue; /* e.g. permission denied — try others */
			}
			*out = h;
			break;
		}
	}
	libusb_free_device_list(devs, 1);
	return *out ? 0 : LIBUSB_ERROR_NOT_FOUND;
}

static int wait_for_pid(unsigned vid, unsigned pid, int timeout_s)
{
	time_t deadline = time(NULL) + timeout_s;
	while (time(NULL) < deadline) {
		libusb_device_handle *h = NULL;
		if (find_device(vid, pid, &h) == 0) {
			libusb_close(h);
			return 0;
		}
		struct timespec ts = { 0, 300 * 1000 * 1000 }; /* 300 ms */
		nanosleep(&ts, NULL);
	}
	return -1;
}

static int dfu_get_status(libusb_device_handle *h, unsigned char st[6])
{
	int transferred = 0;
	int rc = libusb_control_transfer(h, 0xa1, DFU_GETSTATUS, 0, 0, st, 6, 5000);
	if (rc < 0)
		return rc;
	(void)transferred;
	return 0;
}

int main(int argc, char **argv)
{
	const char *path = NULL;
	unsigned pid = 0x1227, wait_pid = 0;
	int timeout_s = 60;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--pid") && i + 1 < argc)
			pid = (unsigned)parse_u32(argv[++i]);
		else if (!strcmp(argv[i], "--wait-pid") && i + 1 < argc)
			wait_pid = (unsigned)parse_u32(argv[++i]);
		else if (!strcmp(argv[i], "--timeout") && i + 1 < argc)
			timeout_s = atoi(argv[++i]);
		else if (!path)
			path = argv[i];
		else {
			fprintf(stderr, "dfu-send: unexpected argument: %s\n", argv[i]);
			return 2;
		}
	}
	if (!path) {
		fprintf(stderr,
			"usage: dfu-send <payload.bin> [--pid 0x1227] [--wait-pid 0x4141] [--timeout 60]\n");
		return 2;
	}

	FILE *fp = fopen(path, "rb");
	if (!fp) {
		fprintf(stderr, "dfu-send: cannot open %s: %s\n", path, strerror(errno));
		return 1;
	}
	fseek(fp, 0, SEEK_END);
	long size = ftell(fp);
	fseek(fp, 0, SEEK_SET);
	if (size <= 0) {
		fprintf(stderr, "dfu-send: %s: empty or unseekable\n", path);
		fclose(fp);
		return 1;
	}
	unsigned char *buf = malloc((size_t)size);
	if (!buf || fread(buf, 1, (size_t)size, fp) != (size_t)size) {
		fprintf(stderr, "dfu-send: read failed: %s\n", path);
		free(buf);
		fclose(fp);
		return 1;
	}
	fclose(fp);
	printf("dfu-send: payload %s (%ld bytes)\n", path, size);

	if (libusb_init(NULL) != 0) {
		fprintf(stderr, "dfu-send: libusb_init failed\n");
		return 1;
	}

	/* Step 1: find the (pwned) DFU device. */
	libusb_device_handle *h = NULL;
	if (find_device(APPLE_VID, pid, &h) != 0) {
		fprintf(stderr,
			"dfu-send: no DFU device %04x:%04x found — is the device in DFU mode? (lsusb)\n",
			APPLE_VID, pid);
		return 1;
	}
	printf("dfu-send: DFU device %04x:%04x opened\n", APPLE_VID, pid);

	if (libusb_set_auto_detach_kernel_driver(h, 0) == LIBUSB_SUCCESS)
		; /* DFU has no kernel driver on Linux; ignore either way */
	if (libusb_claim_interface(h, 0) != LIBUSB_SUCCESS) {
		fprintf(stderr, "dfu-send: libusb_claim_interface(0) failed\n");
		return 1;
	}

	/* Step 2: DFU_DNLOAD the payload in blocks, GETSTATUS after each. */
	long done = 0;
	int wvalue = 0;
	while (done < size) {
		long chunk = size - done;
		if (chunk > CHUNK_SZ)
			chunk = CHUNK_SZ;
		int rc = libusb_control_transfer(h, 0x21, DFU_DNLOAD, wvalue, 0,
						 buf + done, (uint16_t)chunk, 5000);
		if (rc < 0) {
			fprintf(stderr, "dfu-send: DFU_DNLOAD failed at offset %ld: %s\n",
				done, libusb_error_name(rc));
			return 1;
		}
		unsigned char st[6] = { 0 };
		if (dfu_get_status(h, st) != 0) {
			fprintf(stderr, "dfu-send: DFU_GETSTATUS failed after block %d\n", wvalue);
			return 1;
		}
		/* st[4] is bState; 0x05 = dfuDNLOAD-SYNC flow, 0x04 idle-ish.
		 * bStatus st[0] != 0x00 means the device rejected the block. */
		if (st[0] != 0x00) {
			fprintf(stderr, "dfu-send: device reported DFU error status 0x%02x at block %d\n",
				st[0], wvalue);
			return 1;
		}
		done += chunk;
		wvalue++;
	}
	printf("dfu-send: %ld bytes sent in %d DFU block(s)\n", done, wvalue);

	/* Step 3: final GETSTATUS exchange; the pwned bootROM executes the
	 * payload once the last download is accepted. */
	unsigned char st[6] = { 0 };
	if (dfu_get_status(h, st) != 0)
		fprintf(stderr, "dfu-send: warning: final DFU_GETSTATUS failed (continuing)\n");
	else
		printf("dfu-send: final status: bStatus=0x%02x bState=0x%02x\n", st[0], st[4]);

	libusb_release_interface(h, 0);
	libusb_close(h);
	printf("dfu-send: payload handed to DFU\n");

	/* Step 4: optionally wait for the next enumeration state (e.g. pongoOS
	 * appearing as 05ac:4141). */
	if (wait_pid) {
		printf("dfu-send: waiting up to %ds for %04x:%04x to appear...\n",
		       timeout_s, APPLE_VID, wait_pid);
		if (wait_for_pid(APPLE_VID, wait_pid, timeout_s) != 0) {
			fprintf(stderr,
				"dfu-send: TIMED OUT waiting for %04x:%04x — payload may not have executed\n",
				APPLE_VID, wait_pid);
			return 1;
		}
		printf("dfu-send: %04x:%04x present — payload is running\n", APPLE_VID, wait_pid);
	}

	libusb_exit(NULL);
	free(buf);
	return 0;
}
