"""Offline runtime security tests. All values are disposable synthetic fixtures."""
import base64
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True

SOURCE = Path(__file__).resolve().parents[1] / "nix/runtime/netbird-runtime.py"
spec = importlib.util.spec_from_file_location("netbird_runtime", SOURCE)
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.runtime_dir = self.root / "runtime"
        self.secret_paths = {}
        self.values = {
            "authSecret": 'synthetic-only:"\\\n${ENV_NOT_INTERPOLATED} !☃😀\u0085\u2028\u2029\u007f\u009f\ufffe\uffff\n',
            "encryptionKey": base64.b64encode(bytes(range(32))).decode(),
            "sessionCookieEncryptionKey": base64.b64encode(bytes(range(32, 64))).decode(),
        }
        for name, value in self.values.items():
            path = self.root / name
            path.write_text(value, encoding="utf-8")
            path.chmod(0o600)
            self.secret_paths[name] = str(path)
        self.config = {"server": {
            "listenAddress": "127.0.0.1:8081",
            "exposedAddress": "https://netbird.example.test",
            "healthcheckAddress": "127.0.0.1:9000",
            "metricsPort": 9190, "stunPorts": [3478],
            "logLevel": "warn", "logFile": "console",
            "dataDir": "/var/lib/lucidity-netbird",
            "disableAnonymousMetrics": True, "disableGeoliteUpdate": True,
            "store": {"engine": "sqlite"},
            "auth": {"issuer": "https://netbird.example.test/oauth2",
                     "localAuthDisabled": False},
        }}

    def render(self):
        return Path(runtime.render_config(self.config, self.secret_paths, str(self.runtime_dir)))

    def test_exact_secret_bytes_and_no_interpolation(self):
        original = copy.deepcopy(self.config)
        with mock.patch.dict(os.environ, {"ENV_NOT_INTERPOLATED": "not-the-value"}):
            path = self.render()
        result = json.loads(path.read_text())
        self.assertEqual(result["server"]["authSecret"], self.values["authSecret"])
        self.assertEqual(result["server"]["store"]["encryptionKey"], self.values["encryptionKey"])
        self.assertEqual(result["server"]["auth"]["sessionCookieEncryptionKey"], self.values["sessionCookieEncryptionKey"])
        self.assertEqual(self.config, original, "Do not mutate the public base configuration")

    def test_private_atomic_file_permissions(self):
        with mock.patch.object(runtime.os, "replace", wraps=os.replace) as replace:
            path = self.render()
        self.assertEqual(replace.call_count, 1)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.runtime_dir.stat().st_mode), 0o700)
        self.assertEqual(list(self.runtime_dir.iterdir()), [path])
        path.write_text("previous config")
        Path(self.secret_paths["encryptionKey"]).write_text("invalid")
        with self.assertRaises(runtime.SafeError):
            self.render()
        self.assertEqual(path.read_text(), "previous config")
        self.assertEqual(list(self.runtime_dir.iterdir()), [path])

    @unittest.skipUnless(os.environ.get("NETBIRD_TEST_YQ"), "Set NETBIRD_TEST_YQ for Go YAML compatibility")
    def test_rendered_json_roundtrips_through_go_yaml(self):
        """Upstream reads YAML, whose Unicode escapes differ from JSON."""
        path = self.render()
        result = subprocess.run(
            [os.environ["NETBIRD_TEST_YQ"], "-p", "yaml", "-o", "json", ".", str(path)],
            capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(result.returncode, 0, "Synthetic JSON was rejected by Go YAML")
        parsed = json.loads(result.stdout)["server"]
        self.assertEqual(parsed["authSecret"], self.values["authSecret"])
        self.assertEqual(parsed["store"]["encryptionKey"], self.values["encryptionKey"])
        self.assertEqual(parsed["auth"]["sessionCookieEncryptionKey"], self.values["sessionCookieEncryptionKey"])

    def test_failed_atomic_replace_preserves_old_file_and_cleans_temporary(self):
        path = self.render()
        before = path.read_bytes()
        with mock.patch.object(runtime.os, "replace", side_effect=OSError("synthetic failure")):
            with self.assertRaises(runtime.SafeError):
                self.render()
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(list(self.runtime_dir.iterdir()), [path])

    def test_missing_or_empty_secret_fails_before_write(self):
        for name in self.values:
            with self.subTest(name=name):
                path = Path(self.secret_paths[name])
                value = path.read_bytes()
                path.unlink()
                with self.assertRaises(runtime.SafeError):
                    self.render()
                path.write_bytes(b"")
                with self.assertRaises(runtime.SafeError):
                    self.render()
                path.write_bytes(value)
        self.assertFalse(self.runtime_dir.exists() and list(self.runtime_dir.iterdir()))

    def test_secret_path_validation(self):
        for path in ("", "relative", "./credential", "/nix/store/fixture-secret", "/nix/store/../store/fixture-secret"):
            with self.subTest(path=path), self.assertRaises(runtime.SafeError):
                runtime.read_secret(path)

    def test_resolved_store_alias_rejected_before_open(self):
        alias = self.root / "store-alias"
        alias.symlink_to("/nix/store", target_is_directory=True)
        paths = ["/nix/./store/fixture-secret", "/nix/elsewhere/../store/fixture-secret",
                 str(alias / "fixture-secret")]
        for path in paths:
            with self.subTest(path=path), mock.patch.object(runtime.os, "open") as opened:
                with self.assertRaises(runtime.SafeError):
                    runtime.read_secret(path)
                opened.assert_not_called()

    def test_nontext_or_nul_secret_rejected(self):
        path = Path(self.secret_paths["authSecret"])
        for value in (b"\xff", b"synthetic\x00secret"):
            path.write_bytes(value)
            with self.subTest(value=value), self.assertRaises(runtime.SafeError):
                runtime.read_secret(str(path))

    def test_strict_standard_base64_32_byte_keys(self):
        path = Path(self.secret_paths["encryptionKey"])
        good = self.values["encryptionKey"]
        invalid = ["", "not-base64", good + "\n", " " + good, good.rstrip("="),
                   base64.b64encode(b"x" * 16).decode(),
                   base64.b64encode(b"x" * 24).decode(),
                   base64.b64encode(b"x" * 33).decode(),
                   base64.urlsafe_b64encode(b"\xff" * 32).decode(),
                   good[:-2] + "B="]
        for value in invalid:
            path.write_text(value)
            with self.subTest(value=value), self.assertRaises(runtime.SafeError):
                runtime.read_secret(str(path), key=True)
        path.write_text(good)
        self.assertEqual(runtime.read_secret(str(path), key=True), good)

    def test_public_origin_validation(self):
        for origin in ("https://netbird.example.test", "https://netbird.example.test:443", "https://[::1]:8443"):
            runtime.validate_origin(origin)
        for origin in ("", "http://netbird.example.test", "https://u:p@netbird.example.test",
                       "https://netbird.example.test/", "https://netbird.example.test/oauth2",
                       "https://netbird.example.test?q=secret", "https://netbird.example.test#fragment",
                       "https://", "https://netbird.example.test:invalid", "https://bad\x00host",
                       "https://bad\x01host", "https://bad\x7fhost"):
            with self.subTest(origin=origin), self.assertRaises(runtime.SafeError):
                runtime.validate_origin(origin)

    def test_environment_allowlist_at_both_boundaries(self):
        inherited = {"HOME": "/private", "PATH": "/safe/bin", "LANG": "C.UTF-8", "TZ": "UTC",
                     "CREDENTIALS_DIRECTORY": "/run/credentials/fixture",
                     "NB_PROXY_TOKEN": "synthetic-token", "NB_LOG_LEVEL": "debug",
                     "NB_IDP_SESSION_COOKIE_ENCRYPTION_KEY": "synthetic-key",
                     "SECRETSPEC_PROVIDER": "aws-sm", "SECRETSPEC_PROFILE": "attacker",
                     "SECRETSPEC_SCOPE": "attacker", "AWS_SECRET_ACCESS_KEY": "synthetic-aws",
                     "AWS_ACCESS_KEY_ID": "synthetic-id", "VAULT_TOKEN": "synthetic-vault",
                     "BAO_TOKEN": "synthetic-bao", "PYTHONPATH": "/attacker", "LD_PRELOAD": "/attacker"}
        expected = {key: inherited[key] for key in ("HOME", "PATH", "LANG", "TZ")}
        self.assertEqual(runtime.safe_environment(inherited), expected)
        self.assertEqual(runtime.safe_environment(inherited, credentials=True),
                         dict(expected, CREDENTIALS_DIRECTORY=inherited["CREDENTIALS_DIRECTORY"]))

    def test_renderer_never_prints_values(self):
        output, errors = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            self.render()
            Path(self.secret_paths["encryptionKey"]).write_text("SYNTHETIC-INVALID-SENTINEL")
            try:
                self.render()
            except runtime.SafeError as error:
                self.assertNotIn("SYNTHETIC-INVALID-SENTINEL", str(error))
        self.assertEqual(output.getvalue(), "")
        self.assertEqual(errors.getvalue(), "")

    def metadata(self):
        path = self.root / "metadata.json"
        path.write_text(json.dumps({
            "baseConfig": self.config, "runtimeDirectory": str(self.runtime_dir),
            "server": "/synthetic/bin/netbird-server", "secretspec": "/synthetic/bin/secretspec",
            "manifest": "/synthetic/manifest.toml", "python": "/synthetic/bin/python3",
            "helper": str(SOURCE),
        }))
        return str(path)

    def test_launcher_scrubs_before_secretspec(self):
        meta = self.metadata()
        injected = {"HOME": "/private", "PATH": "/safe/bin", "CREDENTIALS_DIRECTORY": "/run/credentials/unit",
                    "SECRETSPEC_PROVIDER": "attacker", "SECRETSPEC_PROFILE": "attacker",
                    "SECRETSPEC_SCOPE": "attacker", "SECRETSPEC_SECRETS": "synthetic-override",
                    "NB_PROXY_TOKEN": "synthetic-token", "AWS_SECRET_ACCESS_KEY": "synthetic-aws"}
        with mock.patch.dict(os.environ, injected, clear=True), mock.patch.object(runtime.os, "execve") as execute:
            self.assertEqual(runtime.main(["launch", meta]), 0)
        execute.assert_called_once()
        executable, argv, env = execute.call_args.args
        self.assertEqual(executable, "/synthetic/bin/secretspec")
        self.assertEqual(argv[1:12], ["run", "--file", "/synthetic/manifest.toml",
                                    "--profile", "default", "--scope", "default",
                                    "--reason", "start NetBird server with scoped runtime credentials",
                                    "--", "/synthetic/bin/python3"])
        home = Path(env["HOME"])
        self.assertEqual(home.parent, self.runtime_dir)
        self.assertEqual(stat.S_IMODE(home.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(Path(env["XDG_CONFIG_HOME"]).stat().st_mode), 0o700)
        self.assertEqual(env, {"HOME": str(home), "PATH": "/safe/bin",
                              "CREDENTIALS_DIRECTORY": "/run/credentials/unit",
                              "SECRETSPEC_PROVIDER": "systemd-credential",
                              "XDG_CONFIG_HOME": str(home / "config"),
                              "XDG_STATE_HOME": str(self.runtime_dir)})
        self.assertNotIn("synthetic-token", str(argv))

    def test_render_exec_has_no_secret_arguments_or_environment(self):
        meta = self.metadata()
        env = {runtime.SECRET_NAMES[name]: path for name, path in self.secret_paths.items()}
        env.update({"HOME": "/private", "PATH": "/safe/bin", "NB_PROXY_TOKEN": "synthetic-token",
                    "SECRETSPEC_PROVIDER": "attacker", "AWS_SECRET_ACCESS_KEY": "synthetic-aws",
                    "CREDENTIALS_DIRECTORY": "/run/credentials/unit"})
        output, errors = io.StringIO(), io.StringIO()
        with mock.patch.dict(os.environ, env, clear=True), mock.patch.object(runtime.os, "execve") as execute, contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            self.assertEqual(runtime.main(["render", meta]), 0)
        executable, argv, final_env = execute.call_args.args
        self.assertEqual(executable, "/synthetic/bin/netbird-server")
        self.assertEqual(argv, [executable, "--config", str(self.runtime_dir / "config.json")])
        self.assertEqual(final_env, {"HOME": "/private", "PATH": "/safe/bin"})
        for secret in self.values.values():
            self.assertNotIn(secret, str(argv))
            self.assertNotIn(secret, str(final_env))
        self.assertEqual(output.getvalue() + errors.getvalue(), "")

    def test_cli_errors_are_generic_without_tracebacks_or_sentinels(self):
        meta = self.metadata()
        env = {runtime.SECRET_NAMES[name]: path for name, path in self.secret_paths.items()}
        Path(self.secret_paths["encryptionKey"]).write_text("SYNTHETIC-INVALID-SENTINEL")
        for test_env in (env, {}):
            output, errors = io.StringIO(), io.StringIO()
            with mock.patch.dict(os.environ, test_env, clear=True), mock.patch.object(runtime.os, "execve") as execute, contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
                self.assertEqual(runtime.main(["render", meta]), 1)
            execute.assert_not_called()
            self.assertEqual(output.getvalue(), "")
            self.assertEqual(errors.getvalue(), "netbird runtime: configuration or credentials rejected\n")

    def test_secret_files_reject_symlinks_directories_fifos_and_oversize(self):
        link = self.root / "link"
        link.symlink_to(self.secret_paths["authSecret"])
        loop = self.root / "loop"
        loop.symlink_to(loop)
        fifo = self.root / "fifo"
        os.mkfifo(fifo)
        large = self.root / "large"
        large.write_bytes(b"x" * 65537)
        for path in (link, loop, fifo, self.root, large):
            with self.subTest(path=path), self.assertRaises(runtime.SafeError):
                runtime.read_secret(str(path))

    def test_runtime_directory_must_be_private_and_not_symlink(self):
        public = self.root / "public"
        public.mkdir(mode=0o755)
        link = self.root / "runtime-link"
        link.symlink_to(public, target_is_directory=True)
        for directory in (public, link):
            with self.subTest(directory=directory), self.assertRaises(runtime.SafeError):
                runtime.render_config(self.config, self.secret_paths, str(directory))
        self.assertEqual(list(public.iterdir()), [])
    @unittest.skipUnless(os.environ.get("NETBIRD_TEST_SECRETSPEC"), "Set NETBIRD_TEST_SECRETSPEC to test the real CLI")
    def test_real_secretspec_systemd_credential_end_to_end(self):
        """Run the real CLI with generated local fixtures and a non-daemon probe."""
        credentials = self.root / "credentials"
        credentials.mkdir(mode=0o700)
        for name, variable in runtime.SECRET_NAMES.items():
            (credentials / variable).write_text(self.values[name], encoding="utf-8")
            (credentials / variable).chmod(0o600)
        manifest = self.root / "secretspec.toml"
        declarations = "\n".join(
            variable + ' = { description = "Synthetic test only", required = true, as_path = true }'
            for variable in runtime.SECRET_NAMES.values()
        )
        manifest.write_text('[project]\nname = "netbird-runtime-test"\nrevision = "1.0"\n'
                            '[profiles.default]\n' + declarations + '\n[scopes.default]\nsecrets = '
                            + json.dumps(list(runtime.SECRET_NAMES.values())) + '\n')
        # Nix checks exercise the exact production generator, not just this
        # standalone fallback fixture (which previously hid revision drift).
        if os.environ.get("NETBIRD_TEST_MANIFEST"):
            manifest = Path(os.environ["NETBIRD_TEST_MANIFEST"])
        self.runtime_dir.mkdir(mode=0o700)
        probe = self.root / "probe"
        probe.write_text("#!" + sys.executable + "\n" +
                         "import json, os, sys\n" +
                         "assert len(sys.argv) == 3 and sys.argv[1] == '--config'\n" +
                         "assert not any(k.startswith(('NB_', 'NETBIRD_', 'SECRETSPEC_', 'AWS_', 'BAO_', 'VAULT_')) for k in os.environ)\n" +
                         "assert 'CREDENTIALS_DIRECTORY' not in os.environ\n" +
                         "assert 'XDG_STATE_HOME' not in os.environ\n" +
                         "with open(sys.argv[2]) as f: config = json.load(f)['server']\n" +
                         "expected = " + repr(self.values) + "\n" +
                         "assert config['authSecret'] == expected['authSecret']\n" +
                         "assert config['store']['encryptionKey'] == expected['encryptionKey']\n" +
                         "assert config['auth']['sessionCookieEncryptionKey'] == expected['sessionCookieEncryptionKey']\n" +
                         "assert all(value not in str(sys.argv) for value in expected.values())\n" +
                         "print('NETBIRD_SYNTHETIC_PROBE_OK')\n")
        probe.chmod(0o700)
        metadata = Path(self.metadata())
        data = json.loads(metadata.read_text())
        data.update(server=str(probe), secretspec=os.environ["NETBIRD_TEST_SECRETSPEC"],
                    manifest=str(manifest), python=sys.executable)
        metadata.write_text(json.dumps(data))
        # Global aliases override explicit builtin provider names in 0.18.
        # A fresh HOME/config boundary must prevent this poisoned config loading.
        poisoned_config = self.root / ".config" / "secretspec"
        poisoned_config.mkdir(parents=True)
        (poisoned_config / "config.toml").write_text(
            '[defaults.providers]\nsystemd-credential = "env://"\n')
        environment = dict(os.environ, HOME=str(self.root), XDG_CONFIG_HOME=str(self.root / ".config"),
                           CREDENTIALS_DIRECTORY=str(credentials),
                           NB_PROXY_TOKEN="SYNTHETIC-INJECTED-TOKEN", SECRETSPEC_PROVIDER="attacker",
                           SECRETSPEC_PROFILE="attacker", SECRETSPEC_SCOPE="attacker",
                           AWS_SECRET_ACCESS_KEY="SYNTHETIC-INJECTED-AWS", BAO_TOKEN="SYNTHETIC-INJECTED-BAO")
        result = subprocess.run([sys.executable, "-I", str(SOURCE), "launch", str(metadata)],
                                env=environment, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, "Real SecretSpec synthetic fixture did not reach the probe")
        self.assertIn("NETBIRD_SYNTHETIC_PROBE_OK", result.stdout)
        for value in list(self.values.values()) + ["SYNTHETIC-INJECTED-TOKEN", "SYNTHETIC-INJECTED-AWS", "SYNTHETIC-INJECTED-BAO"]:
            self.assertNotIn(value, result.stdout + result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        # A missing required provider credential must never reach the probe.
        (credentials / runtime.SECRET_NAMES["sessionCookieEncryptionKey"]).unlink()
        rejected = subprocess.run([sys.executable, "-I", str(SOURCE), "launch", str(metadata)],
                                  env=environment, capture_output=True, text=True, timeout=20)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertNotIn("NETBIRD_SYNTHETIC_PROBE_OK", rejected.stdout)
        for value in self.values.values():
            self.assertNotIn(value, rejected.stdout + rejected.stderr)
        self.assertNotIn("Traceback", rejected.stderr)


if __name__ == "__main__":
    unittest.main()
