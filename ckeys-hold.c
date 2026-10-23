/*
 * ckeys-hold - avisa a DMS cuando se mantienen presionadas las teclas de la
 * combinacion (por defecto Mod+Shift+C), para que la barra de C-Key aparezca
 * solo mientras estan apretadas.
 *
 * Mientras la combinacion esta apretada tambien agarra el touchpad (y su
 * nodo "Mouse" hermano) y manda las coordenadas del dedo a DMS, para que el
 * touchpad funcione como touch bar. El teclado se lee sin grab, asi que no
 * interfiere con nada.
 *
 * Uso: ckeys-hold [mod] [shift] [tecla] [--touchpad]
 */

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <math.h>
#include <time.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <signal.h>
#include <sys/types.h>
#include <grp.h>
#include <pwd.h>
#include <unistd.h>

#define MAX_DEVS 32
#define KEY_BYTES ((KEY_MAX + 8) / 8)
#define ABS_BYTES ((ABS_MAX + 8) / 8)

#define KIND_KEYBOARD 0
#define KIND_TOUCHPAD 1
#define KIND_POINTER 2

struct dev {
	int fd;
	int event_no;
	int kind;
	char phys[128];
	int x_min, x_max, y_min, y_max;  /* rangos del multitactil */
};

static int mod_key = KEY_LEFTMETA;
static int shift_key = KEY_LEFTSHIFT;
static int trigger_key = KEY_C;
static int use_touchpad = 1;

static struct dev devs[MAX_DEVS];
static int ndevs = 0;

static int tp_index = -1;  /* el touchpad que usamos como touch bar */

/* los punteros se agarran mientras el panel esta activo, para que el cursor
 * no se mueva y los clics no lleguen a la aplicacion */
static int pointer_index[MAX_DEVS];
static int n_pointers = 0;

static int abs_x_min, abs_x_max, abs_y_min, abs_y_max;

static int grabbed = 0;

/* ------------------------------------------------------------------ util */

/* Root es la unica forma de abrir /dev/input, pero el IPC lo tiene que
 * hacer el usuario de la sesion. */
static uid_t session_uid(void) {
	const char *uid = getenv("CKEYS_UID");
	if (uid && *uid)
		return (uid_t)atoi(uid);
	return getuid();
}

/* El gid no siempre es igual al uid. */
static gid_t session_gid(void) {
	const char *gid = getenv("CKEYS_GID");
	if (gid && *gid)
		return (gid_t)atoi(gid);

	struct passwd *pw = getpwuid(session_uid());
	if (pw)
		return pw->pw_gid;
	return getgid();
}

/* Si arranca como root, baja al usuario de la sesion para el IPC. */
static void drop_privileges(void) {
	if (geteuid() != 0)
		return;

	uid_t uid = session_uid();
	gid_t gid = session_gid();

	if (setgroups(0, NULL) < 0 || setgid(gid) < 0)
		_exit(127);
	if (setuid(uid) < 0)
		_exit(127);

	char runtime[128];  /* el runtime y el home son los del usuario */
	snprintf(runtime, sizeof(runtime), "/run/user/%u", (unsigned)uid);
	setenv("XDG_RUNTIME_DIR", runtime, 1);

	struct passwd *pw = getpwuid(uid);
	if (pw && pw->pw_dir)
		setenv("HOME", pw->pw_dir, 1);

	if (!getenv("DISPLAY"))
		setenv("DISPLAY", ":0", 1);
}

static int fallos_ipc = 0;

/* Corre argv como el usuario de la sesion y junta su stdout en out.
 * Sin shell y sin heredar los fds de /dev/input. */
static int run_capture(const char *const argv[], char *out, size_t outlen) {
	int p[2];
	if (pipe(p) < 0)
		return 0;

	pid_t pid = fork();
	if (pid < 0) {
		close(p[0]);
		close(p[1]);
		return 0;
	}

	if (pid == 0) {
		dup2(p[1], STDOUT_FILENO);
		close(p[0]);
		close(p[1]);
		drop_privileges();
		execvp(argv[0], (char *const *)argv);
		_exit(127);
	}

	close(p[1]);
	size_t used = 0;
	ssize_t n;
	while (used + 1 < outlen && (n = read(p[0], out + used, outlen - 1 - used)) > 0)
		used += (size_t)n;
	out[used] = '\0';
	close(p[0]);

	int status = 0;
	waitpid(pid, &status, 0);
	return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

/* Corre argv como el usuario de la sesion, sin shell. */
static void run_quiet(const char *const argv[]) {
	pid_t pid = fork();
	if (pid == 0) {
		drop_privileges();
		execvp(argv[0], (char *const *)argv);
		_exit(127);
	}
	if (pid > 0) {
		int status = 0;
		waitpid(pid, &status, 0);
	}
}

/* Si el display X11 tiene exactamente ese tamano, es la pantalla que cubre
 * xwayland-satellite. */
static int x11_cubre(int w, int h) {
	char out[64];
	const char *argv[] = { "xdotool", "getdisplaygeometry", NULL };

	if (!run_capture(argv, out, sizeof(out)))
		return 0;

	int dw = 0, dh = 0;
	return sscanf(out, "%d %d", &dw, &dh) == 2 && dw == w && dh == h;
}

static void notify(const char *action) {
	pid_t pid = fork();
	if (pid == 0) {
		drop_privileges();
		execlp("dms", "dms", "ipc", "call", "ckeys", action, (char *)NULL);
		_exit(127);
	}
	if (pid > 0) {
		int status = 0;
		waitpid(pid, &status, 0);
		if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
			fallos_ipc++;
			fprintf(stderr, "ckeys-hold: el IPC de %s fallo (status %d)\n", action, status);
		} else {
			fallos_ipc = 0;
		}
	}
}

static void notify_xy(const char *action, double x, double y) {
	char xbuf[32], ybuf[32];
	snprintf(xbuf, sizeof(xbuf), "%.4f", x);
	snprintf(ybuf, sizeof(ybuf), "%.4f", y);

	pid_t pid = fork();
	if (pid == 0) {
		drop_privileges();
		execlp("dms", "dms", "ipc", "call", "ckeys", action, xbuf, ybuf, (char *)NULL);
		_exit(127);
	}
	if (pid > 0) {
		int status = 0;
		waitpid(pid, &status, 0);
		if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
			fprintf(stderr, "ckeys-hold: el IPC de %s %s %s fallo (status %d)\n",
			        action, xbuf, ybuf, status);
	}
}

/* Mouse virtual para mover el cursor. */
static int uinput_mouse = -1;

static int open_virtual_mouse(void) {
	if (uinput_mouse >= 0)
		return uinput_mouse;

	int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
	if (fd < 0)
		return -1;

	if (ioctl(fd, UI_SET_EVBIT, EV_SYN) < 0 || ioctl(fd, UI_SET_EVBIT, EV_KEY) < 0 ||
	    ioctl(fd, UI_SET_EVBIT, EV_REL) < 0) {
		close(fd);
		return -1;
	}
	ioctl(fd, UI_SET_KEYBIT, BTN_LEFT);
	ioctl(fd, UI_SET_RELBIT, REL_X);
	ioctl(fd, UI_SET_RELBIT, REL_Y);

	struct uinput_setup setup;
	memset(&setup, 0, sizeof(setup));
	setup.id.bustype = BUS_VIRTUAL;
	setup.id.vendor = 0x1209;
	setup.id.product = 0x0002;
	setup.id.version = 1;
	strncpy(setup.name, "ckeys-cursor", UINPUT_MAX_NAME_SIZE - 1);

	if (ioctl(fd, UI_DEV_SETUP, &setup) < 0 || ioctl(fd, UI_DEV_CREATE) < 0) {
		close(fd);
		return -1;
	}

	usleep(300000);
	uinput_mouse = fd;
	return fd;
}

static void emit_rel(int fd, int code, int value) {
	struct input_event ev;
	memset(&ev, 0, sizeof(ev));
	ev.type = EV_REL;
	ev.code = (unsigned short)code;
	ev.value = value;
	ssize_t written = write(fd, &ev, sizeof(ev));
	(void)written;
}

static void flush_sync(int fd) {
	struct input_event ev;
	memset(&ev, 0, sizeof(ev));
	ev.type = EV_SYN;
	ev.code = SYN_REPORT;
	ssize_t written = write(fd, &ev, sizeof(ev));
	(void)written;
}

/* El plugin devuelve el centro de la pantalla donde esta el panel. Con un
 * mouse virtual primero se empuja el cursor a una esquina (el compositor lo
 * topa ahi, sin importar la aceleracion) y despues se aplica el delta. */
static void move_cursor_to_center(void) {
	char out[160];
	const char *center_argv[] = { "dms", "ipc", "call", "ckeys", "center", NULL };

	if (!run_capture(center_argv, out, sizeof(out)))
		return;

	int cx = 0, cy = 0, sw = 0, sh = 0;
	int ok = (sscanf(out, "%d %d %d %d", &cx, &cy, &sw, &sh) == 4 && cx > 0 && cy > 0);

	if (!ok)
		return;

	/* en la pantalla de xwayland-satellite el movimiento absoluto de X11
	 * es exacto */
	if (x11_cubre(sw, sh)) {
		char xbuf[16], ybuf[16];
		snprintf(xbuf, sizeof(xbuf), "%d", cx);
		snprintf(ybuf, sizeof(ybuf), "%d", cy);

		const char *move_argv[] = { "xdotool", "mousemove", xbuf, ybuf, NULL };
		run_quiet(move_argv);
		return;
	}

	int fd = open_virtual_mouse();
	if (fd < 0)
		return;

	/* esquina superior izquierda */
	for (int i = 0; i < 8; i++) {
		emit_rel(fd, REL_X, -2000);
		emit_rel(fd, REL_Y, -2000);
		flush_sync(fd);
	}
	usleep(60000);

	/* hasta el centro */
	emit_rel(fd, REL_X, cx);
	emit_rel(fd, REL_Y, cy);
	flush_sync(fd);
	usleep(60000);
}

static int bit_is_set(const unsigned char *bits, int code) {
	return (bits[code / 8] >> (code % 8)) & 1;
}

/* EVIOCGKEY no devolvia el estado en este sistema, asi que el estado de
 * cada tecla se sigue a mano con los eventos EV_KEY. */
static unsigned char key_state[KEY_MAX + 1];

static void track_key_event(int code, int value) {
	if (code < 0 || code > KEY_MAX)
		return;
	if (value == 0)
		key_state[code] = 0;
	else if (value == 1)
		key_state[code] = 1;
	/* value == 2 es autorepeat: el estado no cambia */
}

static int key_is_down(int code) {
	if (code < 0 || code > KEY_MAX)
		return 0;
	return key_state[code] ? 1 : 0;
}

/* el dispositivo es capaz de reportar esta tecla? (capacidades) */
static int supports_key(int fd, int code) {
	unsigned char bits[KEY_BYTES];
	memset(bits, 0, sizeof(bits));

	if (ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(bits)), bits) < 0)
		return 0;

	return bit_is_set(bits, code);
}

/* la tecla esta apretada ahora mismo? (estado) */
static int has_abs(int fd, int code) {
	unsigned char bits[ABS_BYTES];
	memset(bits, 0, sizeof(bits));

	if (ioctl(fd, EVIOCGBIT(EV_ABS, sizeof(bits)), bits) < 0)
		return 0;

	return bit_is_set(bits, code);
}

static int has_rel(int fd, int code) {
	unsigned char bits[ABS_BYTES];
	memset(bits, 0, sizeof(bits));

	if (ioctl(fd, EVIOCGBIT(EV_REL, sizeof(bits)), bits) < 0)
		return 0;

	return bit_is_set(bits, code);
}

/* el PHYS es lo que une al touchpad con su nodo "Mouse" hermano */
static void read_phys(int event_no, char *out, size_t len) {
	out[0] = '\0';

	char path[256];
	snprintf(path, sizeof(path), "/sys/class/input/event%d/device/uevent", event_no);

	FILE *f = fopen(path, "r");
	if (!f)
		return;

	char line[512];
	while (fgets(line, sizeof(line), f)) {
		if (strncmp(line, "PHYS=", 5) == 0) {
			char *start = strchr(line, '"');
			char *end = strrchr(line, '"');
			if (start && end && end > start) {
				size_t n = (size_t)(end - start - 1);
				if (n >= len)
					n = len - 1;
				memcpy(out, start + 1, n);
				out[n] = '\0';
			}
			break;
		}
	}
	fclose(f);
}

static int axis_range(int fd, int code, int *min, int *max) {
	int data[6];
	memset(data, 0, sizeof(data));

	if (ioctl(fd, EVIOCGABS(code), data) < 0)
		return 0;

	*min = data[1];
	*max = data[2];
	return 1;
}

/* ------------------------------------------------------------------ grab */

static int grab(int fd, int on) {
	return ioctl(fd, EVIOCGRAB, on) == 0;
}

static void grab_pointers(int on) {
	for (int i = 0; i < n_pointers; i++) {
		if (!grab(devs[pointer_index[i]].fd, on ? 1 : 0))
			fprintf(stderr, "ckeys-hold: no pude %s el puntero %d: %s\n",
			        on ? "agarrar" : "soltar", pointer_index[i], strerror(errno));
	}

	grabbed = on;
	fprintf(stderr, "ckeys-hold: %d puntero(s) %s\n", n_pointers,
	        on ? "agarrados (cursor bloqueado)" : "soltados");
}

/* ----------------------------------------------------------------- estado */

static int combo_held(void) {
	int mod = key_is_down(mod_key) || key_is_down(KEY_RIGHTMETA);
	int shift = key_is_down(shift_key) || key_is_down(KEY_RIGHTSHIFT);
	int trigger = key_is_down(trigger_key);

	return mod && shift && trigger;
}

/* ----------------------------------------------------------------- touch */

/* Un IPC por cada evento de movimiento es demasiado lento (cada llamada
 * arranca el cliente de DMS), asi que se agrupan y se manda uno cada
 * TOUCH_MIN_INTERVAL_MS, y solo si las coordenadas cambiaron. */
#define TOUCH_MIN_INTERVAL_MS 25
#define TOUCH_MIN_DELTA 0.0015

static double last_touch_x = -1.0;
static double last_touch_y = -1.0;
static struct timespec last_touch_at;

static long ms_since(const struct timespec *then) {
	struct timespec now;
	clock_gettime(CLOCK_MONOTONIC, &now);
	return (now.tv_sec - then->tv_sec) * 1000 + (now.tv_nsec - then->tv_nsec) / 1000000;
}

static void send_touch(double x, double y) {
	long elapsed = ms_since(&last_touch_at);

	if (elapsed < TOUCH_MIN_INTERVAL_MS)
		return;
	if (last_touch_x >= 0 &&
	    fabs(x - last_touch_x) < TOUCH_MIN_DELTA &&
	    fabs(y - last_touch_y) < TOUCH_MIN_DELTA)
		return;

	last_touch_x = x;
	last_touch_y = y;
	clock_gettime(CLOCK_MONOTONIC, &last_touch_at);
	notify_xy("touch", x, y);
}

static void handle_touchpad_events(int fd, int idx, int enviar) {
	const struct dev *dev = &devs[idx];
	struct input_event ev;
	int slot_x = -1, slot_y = -1;
	int have_x = 0, have_y = 0;

	while (read(fd, &ev, sizeof(ev)) == (ssize_t)sizeof(ev)) {
		if (ev.type == EV_KEY && ev.code == BTN_TOUCH && ev.value == 0) {
			/* el dedo tambien se levanta con BTN_TOUCH = 0 */
			have_x = 0;
			have_y = 0;
			if (enviar)
				notify("release");
			continue;
		}

		if (ev.type != EV_ABS)
			continue;

		switch (ev.code) {
		case ABS_MT_POSITION_X:
			slot_x = ev.value;
			have_x = 1;
			break;
		case ABS_MT_POSITION_Y:
			slot_y = ev.value;
			have_y = 1;
			break;
		case ABS_MT_TRACKING_ID:
			/* el dedo se levanto: hay que avisarle al plugin, si no
			 * el primer toque deja el panel en estado "arrastrando" y
			 * los toques siguientes nunca presionan una tecla */
			if (ev.value == -1) {
				have_x = 0;
				have_y = 0;
				if (enviar)
					notify("release");
			}
			continue;
		default:
			continue;
		}

		if (!have_x || !have_y || slot_x < 0 || slot_y < 0)
			continue;

		double span_x = (double)(dev->x_max - dev->x_min);
		double span_y = (double)(dev->y_max - dev->y_min);
		if (span_x <= 0 || span_y <= 0)
			continue;

		double x = (slot_x - dev->x_min) / span_x;
		double y = (slot_y - dev->y_min) / span_y;

		if (x < 0) x = 0;
		if (x > 1) x = 1;
		if (y < 0) y = 0;
		if (y > 1) y = 1;

		have_x = 0;
		have_y = 0;
		if (enviar)
			send_touch(x, y);
	}
}

/* ------------------------------------------------------------------ main */

static char pidfile_path[128] = "";

/* el pidfile va en el runtime del usuario de la sesion */
static void armar_pidfile(void) {
	snprintf(pidfile_path, sizeof(pidfile_path), "/run/user/%u/ckeys-hold.pid",
	         (unsigned)session_uid());
}

/* Si ya hay otra instancia viva, esta se va. */
static int otra_instancia_viva(void) {
	int fd = open(pidfile_path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
	if (fd < 0)
		return 0;

	FILE *f = fdopen(fd, "r");
	if (!f) {
		close(fd);
		return 0;
	}

	int pid = 0;
	if (fscanf(f, "%d", &pid) != 1)
		pid = 0;
	fclose(f);

	if (pid <= 0 || pid == getpid())
		return 0;
	if (kill(pid, 0) != 0)
		return 0;

	char cmd[64];
	snprintf(cmd, sizeof(cmd), "/proc/%d/comm", pid);
	FILE *c = fopen(cmd, "r");
	if (!c)
		return 0;
	char comm[64] = {0};
	if (!fgets(comm, sizeof(comm), c)) {
		fclose(c);
		return 0;
	}
	fclose(c);
	return strstr(comm, "ckeys-hold") != NULL;
}

/* El directorio es del usuario, asi que root no puede seguir symlinks ni
 * confiar en un archivo que ya exista ahi. */
static void escribir_pidfile(void) {
	unlink(pidfile_path);

	int fd = open(pidfile_path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
	if (fd < 0) {
		fprintf(stderr, "ckeys-hold: no pude escribir %s: %s\n",
		        pidfile_path, strerror(errno));
		return;
	}

	if (geteuid() == 0) {
		int rc = fchown(fd, session_uid(), session_gid());
		(void)rc;
	}

	char buf[32];
	int n = snprintf(buf, sizeof(buf), "%d\n", (int)getpid());
	if (n > 0) {
		ssize_t written = write(fd, buf, (size_t)n);
		(void)written;
	}
	close(fd);
}

int main(int argc, char **argv) {
	int positional = 0;

	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--touchpad") == 0)
			use_touchpad = 1;
		else if (strcmp(argv[i], "--no-touchpad") == 0)
			use_touchpad = 0;
		else
			positional++;
	}

	armar_pidfile();
	if (otra_instancia_viva()) {
		fprintf(stderr, "ckeys-hold: ya hay otra instancia corriendo\n");
		return 0;
	}
	escribir_pidfile();

	if (positional > 0) mod_key = atoi(argv[1]);
	if (positional > 1) shift_key = atoi(argv[2]);
	if (positional > 2) trigger_key = atoi(argv[3]);

	char phys[MAX_DEVS][128];

	for (int i = 0; i < 64 && ndevs < MAX_DEVS; i++) {
		char path[64];
		snprintf(path, sizeof(path), "/dev/input/event%d", i);

		int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
		if (fd < 0)
			continue;

		int kind = -1;

		if (supports_key(fd, KEY_A) || supports_key(fd, KEY_C))
			kind = KIND_KEYBOARD;
		else if (has_abs(fd, ABS_MT_POSITION_X) && has_abs(fd, ABS_MT_POSITION_Y))
			kind = KIND_TOUCHPAD;
		else if (has_rel(fd, REL_X) && has_rel(fd, REL_Y))
			kind = KIND_POINTER;

		if (kind < 0) {
			close(fd);
			continue;
		}

		devs[ndevs].fd = fd;
		devs[ndevs].event_no = i;
		devs[ndevs].kind = kind;
		read_phys(i, phys[ndevs], sizeof(phys[ndevs]));

		if (kind == KIND_TOUCHPAD)
			axis_range(fd, ABS_MT_POSITION_X, &devs[ndevs].x_min, &devs[ndevs].x_max);
		if (kind == KIND_TOUCHPAD)
			axis_range(fd, ABS_MT_POSITION_Y, &devs[ndevs].y_min, &devs[ndevs].y_max);

		if (kind == KIND_POINTER || kind == KIND_TOUCHPAD) {
			if (n_pointers < MAX_DEVS)
				pointer_index[n_pointers++] = ndevs;
		}

		ndevs++;
	}

	/* el touchpad y su nodo hermano comparten PHYS */
	if (use_touchpad) {
		for (int i = 0; i < ndevs; i++) {
			if (devs[i].kind != KIND_TOUCHPAD)
				continue;
			tp_index = i;
			axis_range(devs[i].fd, ABS_MT_POSITION_X, &abs_x_min, &abs_x_max);
			axis_range(devs[i].fd, ABS_MT_POSITION_Y, &abs_y_min, &abs_y_max);

			break;
		}
	}

	int keyboards = 0;
	for (int i = 0; i < ndevs; i++)
		if (devs[i].kind == KIND_KEYBOARD)
			keyboards++;

	if (keyboards == 0) {
		fprintf(stderr, "ckeys-hold: no encontre ningun teclado\n");
		return 1;
	}

	fprintf(stderr, "ckeys-hold: %d teclado(s), %d puntero(s)", keyboards, n_pointers);
	if (tp_index >= 0)
		fprintf(stderr, ", touchpad %d (x %d..%d, y %d..%d)",
		        tp_index, abs_x_min, abs_x_max, abs_y_min, abs_y_max);
	fprintf(stderr, ", esperando Mod(%d)+Shift(%d)+%d\n", mod_key, shift_key, trigger_key);

	struct pollfd pfd[MAX_DEVS];
	for (int i = 0; i < ndevs; i++) {
		pfd[i].fd = devs[i].fd;
		pfd[i].events = POLLIN;
		pfd[i].revents = 0;
	}

	int held = combo_held();
	notify(held ? "show" : "hide");
	if (held && tp_index >= 0)
		grab_pointers(1);

	for (;;) {
		int ready = poll(pfd, ndevs, 2000);
		if (ready < 0) {
			if (errno == EINTR)
				continue;
			break;
		}

		for (int i = 0; i < ndevs; i++) {
			if (pfd[i].revents & (POLLHUP | POLLERR | POLLNVAL)) {
				/* el dispositivo fue destruido y recreado: el fd quedo viejo.
				 * Se cierra y se vuelve a abrir por numero. */
				fprintf(stderr, "ckeys-hold: dispositivo %d se fue, lo reabro\n", i);
				close(devs[i].fd);
				char path[64];
				snprintf(path, sizeof(path), "/dev/input/event%d", devs[i].event_no);
				int nfd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
				if (nfd < 0)
					continue;
				devs[i].fd = nfd;
				pfd[i].fd = nfd;
				pfd[i].revents = 0;
				continue;
			}

			if (!(pfd[i].revents & POLLIN))
				continue;

			if (devs[i].kind == KIND_TOUCHPAD)
				handle_touchpad_events(devs[i].fd, i, grabbed);
			else {
				struct input_event ev;
				while (read(devs[i].fd, &ev, sizeof(ev)) == (ssize_t)sizeof(ev)) {
					if (ev.type == EV_KEY)
						track_key_event(ev.code, ev.value);
				}
			}
		}

		if (fallos_ipc >= 5) {
			fprintf(stderr, "ckeys-hold: DMS no responde, salgo\n");
			unlink(pidfile_path);
			return 0;
		}

		int now = combo_held();
		if (now != held) {
			held = now;
			fprintf(stderr, "ckeys-hold: combinacion %s\n", held ? "apretada" : "suelta");

			if (held) {
				/* mientras la combinacion este apretada se agarran los
				 * punteros: el cursor no se mueve y los toques del
				 * touchpad los leemos nosotros */
				grab_pointers(1);
			} else {
				grab_pointers(0);
				last_touch_x = -1.0;
				last_touch_y = -1.0;
				notify("release");
				move_cursor_to_center();
			}

			notify(held ? "show" : "hide");
		}
	}

	return 0;
}
