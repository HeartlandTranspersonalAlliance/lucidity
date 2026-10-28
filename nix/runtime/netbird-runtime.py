"""Private NetBird configuration boundary. Never print exceptions or secret data."""
import base64
import copy
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
from urllib.parse import urlsplit

SECRET_NAMES = {
    "authSecret": "NETBIRD_AUTH_SECRET",
    "encryptionKey": "NETBIRD_STORE_KEY",
    "sessionCookieEncryptionKey": "NETBIRD_COOKIE_KEY",
}


class SafeError(Exception):
    pass


def safe_environment(environ, credentials=False):
    # No NB_*, provider credentials, Python injection or SECRETSPEC_* routing.
    result = {k: environ[k] for k in ("HOME", "PATH", "LANG", "TZ") if k in environ}
    if credentials and "CREDENTIALS_DIRECTORY" in environ:
        result["CREDENTIALS_DIRECTORY"] = environ["CREDENTIALS_DIRECTORY"]
    return result


def validate_origin(origin):
    try:
        u = urlsplit(origin)
        if (u.scheme != "https" or not u.hostname or u.username is not None
                or u.password is not None or u.path or u.query or u.fragment
                or "?" in origin or "#" in origin or any(c.isspace() or ord(c) < 0x20 or ord(c) == 0x7f for c in origin)
                or "\\" in origin or (u.port is not None and not 1 <= u.port <= 65535)):
            raise ValueError()
    except (TypeError, ValueError):
        raise SafeError("invalid HTTPS origin") from None
    return origin


def read_secret(path, key=False):
    try:
        p = Path(path)
        if (not p.is_absolute() or str(p.resolve()).startswith("/nix/store/")
                or str(p.resolve()) == "/nix/store"):
            raise ValueError()
        # Reject special files and symlinks; bound reads to avoid unbounded input.
        fd = os.open(p, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as f:
            if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
                raise ValueError()
            raw = f.read(65537)
        if not raw or len(raw) > 65536:
            raise ValueError()
        value = raw.decode("utf-8")
        if "\x00" in value:
            raise ValueError()
        if key:
            decoded = base64.b64decode(raw, validate=True)
            if len(decoded) != 32 or base64.b64encode(decoded) != raw:
                raise ValueError()
        return value
    except (OSError, TypeError, ValueError, UnicodeError, RuntimeError):
        raise SafeError("invalid runtime credential") from None


def private_runtime_directory(runtime_dir):
    try:
        directory = Path(runtime_dir)
        if not directory.is_absolute() or directory.is_symlink():
            raise ValueError()
        directory.mkdir(mode=0o700, parents=False, exist_ok=True)
        st = directory.stat()
        if st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) != 0o700:
            raise ValueError()
        return directory
    except (OSError, TypeError, ValueError, RuntimeError):
        raise SafeError("invalid runtime directory") from None


def render_config(base_config, secret_paths, runtime_dir):
    try:
        config = copy.deepcopy(base_config)
        server = config["server"]
        validate_origin(server["exposedAddress"])
        secrets = {name: read_secret(secret_paths[name], key=name != "authSecret")
                   for name in SECRET_NAMES}
        server["authSecret"] = secrets["authSecret"]
        server["store"]["encryptionKey"] = secrets["encryptionKey"]
        server["auth"]["sessionCookieEncryptionKey"] = secrets["sessionCookieEncryptionKey"]
        directory = private_runtime_directory(runtime_dir)
        target = directory / "config.json"
        fd, temporary = tempfile.mkstemp(prefix=".config-", dir=directory)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                os.fchmod(f.fileno(), 0o600)
                # Go's YAML parser rejects JSON surrogate-pair escapes. Emit
                # Unicode scalars directly, but escape YAML line separators and
                # non-printable BMP characters to preserve their exact bytes.
                encoded = json.dumps(config, ensure_ascii=False)
                escapes = {c: "\\u%04x" % c for c in range(0x7f, 0xa0)}
                escapes.update({c: "\\u%04x" % c for c in (0x2028, 0x2029, 0xfffe, 0xffff)})
                f.write(encoded.translate(escapes))
                f.flush()
                os.fsync(f.fileno())
            os.replace(temporary, target)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        return str(target)
    except (KeyError, OSError, TypeError, ValueError):
        raise SafeError("runtime configuration rejected") from None


def main(argv=None):
    try:
        args = sys.argv[1:] if argv is None else argv
        if len(args) != 2 or args[0] not in ("launch", "render"):
            raise SafeError("invalid runtime invocation")
        with open(args[1], encoding="utf-8") as f:
            meta = json.load(f)
        if args[0] == "launch":
            env = safe_environment(os.environ, credentials=True)
            # Explicit provider is metadata, never inherited routing. --scope is
            # not an environment scrubber; both process boundaries are scrubbed.
            directory = private_runtime_directory(meta["runtimeDirectory"])
            # SecretSpec global aliases override even explicit builtin provider
            # names. Never load persistent/inherited HOME or XDG configuration.
            home = tempfile.mkdtemp(prefix="provider-", dir=directory)
            config_home = str(Path(home) / "config")
            os.mkdir(config_home, 0o700)
            env["HOME"] = home
            env["XDG_CONFIG_HOME"] = config_home
            env["SECRETSPEC_PROVIDER"] = "systemd-credential"
            env["XDG_STATE_HOME"] = str(directory)
            command = [meta["secretspec"], "run", "--file", meta["manifest"],
                       "--profile", "default", "--scope", "default",
                       "--reason", "start NetBird server with scoped runtime credentials", "--",
                       meta["python"], "-I", meta["helper"], "render", args[1]]
            os.execve(command[0], command, env)
        else:
            paths = {name: os.environ[env] for name, env in SECRET_NAMES.items()}
            path = render_config(meta["baseConfig"], paths, meta["runtimeDirectory"])
            command = [meta["server"], "--config", path]
            os.execve(command[0], command, safe_environment(os.environ))
    except (SafeError, OSError, ValueError, KeyError, TypeError):
        print("netbird runtime: configuration or credentials rejected", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
