#include "common.h"
#include "io.h"

void
IO_init(IO *io, int fd, cb_io_t func, void *arg)
{
	memset(io, 0, sizeof *io);

	io->fd = fd;
	io->func = func;
	io->arg = arg;
	GS_BUF_init(&io->buf, 1024);
}

// Return -1 on error
static ssize_t
io_write(IO *io, void *data, size_t len, bool is_from_buf)
{
	ssize_t ret;
	ret = write(io->fd, data, len);
	// DEBUGF("write(%zu)=%zd\n", len, ret);
	if (ret < 0)
	{
		if (errno != EAGAIN)
		{
			io->ev_id = IO_EV_ERROR;
			if (io->func != NULL)
				(*io->func)(io, IO_EV_ERROR, io->arg);
			return -1; // FATAL socket error
		}

		ret = 0; // If blocking then zero bytes were written
	}

	if (ret == len)
	{
		if (io->ev_id == IO_EV_WRITE_BLOCKING)
		{
			// Callback if socket was previously blocking
			io->ev_id = IO_EV_WRITE_SUCCESS;
			if (io->func != NULL)
				(*io->func)(io, IO_EV_WRITE_SUCCESS, io->arg);
		}
	} else {
		// HERE: Not all bytes written.
		if (io->ev_id != IO_EV_WRITE_BLOCKING)
		{
			io->ev_id = IO_EV_WRITE_BLOCKING;
			if (io->func != NULL)
				(*io->func)(io, IO_EV_WRITE_BLOCKING, io->arg);
		}
	}

	if (is_from_buf)
	{
		GS_BUF_del(&io->buf, ret);

		return len;
	}

	// HERE: write() not from buffer but from *data directly
	if (ret < len)
		GS_BUF_add_data(&io->buf, (char *)data + ret, len - ret);

	return len;
}

// Return either -1 or len.
// If write() to fd blocks then call callback and buffer data.
ssize_t
IO_write(IO *io, void *data, size_t len)
{
	int is_from_buf = 0;
	size_t len_all = len;

	if (!GS_BUF_IS_INIT(&io->buf))
		return -1;

	if (len == 0)
		return 0;

	if (IO_IS_PAUSED(io))
	{
		// DEBUGF_G("IO is paused. Buffering %zu bytes (already %zu)\n", len, GS_BUF_USED(&io->buf));
		GS_BUF_add_data(&io->buf, data, len);
		return len;
	}

	// If data in buffer then append new data to buffer first so that all can
	// be written with a single call to write().
	if (GS_BUF_USED(&io->buf) > 0)
	{
		GS_BUF_add_data(&io->buf, data, len);
		data = GS_BUF_DATA(&io->buf);
		len_all = GS_BUF_USED(&io->buf);
		is_from_buf = 1;
	}

	if (io_write(io, data, len_all, is_from_buf) < 0)
		return -1;

	return len;
}

// Return -1 on error.
int
IO_flush(IO *io)
{
	if (!GS_BUF_IS_INIT(&io->buf))
		return -1;

	if (GS_BUF_USED(&io->buf) <= 0)
		return 0; // No data to be flushed.

	ssize_t ret;

	ret = io_write(io, GS_BUF_DATA(&io->buf), GS_BUF_USED(&io->buf), true);
	if (ret < 0)
		return -1;

	return 0;
}

void
IO_unpause(IO *io)
{
	io->flags &= ~IO_FL_PAUSED;

	// DEBUGF_G("IO is UNpaused. Flushing %zu bytes\n", GS_BUF_USED(&io->buf));
	IO_flush(io);
}

void
IO_free(IO *io)
{
	if (!GS_BUF_IS_INIT(&io->buf))
		return;

	GS_BUF_free(&io->buf);
	io->func = NULL;
}
