
#include "buf.h"
typedef void (*cb_io_t)(void *io, int ev_id, void *arg);

typedef struct
{
	int fd;
	int ev_id;
	int flags;
	GS_BUF buf;
	cb_io_t func;
	void *arg;
} IO;

// Event IDs
#define IO_EV_WRITE_BLOCKING    (0x01)
#define IO_EV_WRITE_SUCCESS     (0x02)
#define IO_EV_ERROR             (0x03)

#define IO_FL_PAUSED            (0x01)

void IO_init(IO *io, int fd, cb_io_t func, void *arg);
ssize_t IO_write(IO *io, void *data, size_t len);
void IO_free(IO *io);
int IO_flush(IO *io);
void IO_unpause(IO *io);

#define IO_BUF_USED(io)         GS_BUF_USED(&(io)->buf)
#define IO_pause(io)            (io)->flags |= IO_FL_PAUSED
#define IO_IS_PAUSED(io)        ((io)->flags & IO_FL_PAUSED)
#define IO_get_fd(io)           (io)->fd

