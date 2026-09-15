"""Exercise the native Baseten entry point without deploying anything."""

import contextlib
import importlib.util
import io
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1] / "baseten"
SPEC = importlib.util.spec_from_file_location("push_truss", ROOT / "push_truss.py")
push = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(push)


def invoke(*args):
    output = io.StringIO()
    with patch("sys.argv", ["push_truss.py", *args]):
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            result = push.main()
    return result, output.getvalue()


class BasetenTests(unittest.TestCase):
    def test_profile_wrappers_preview_their_own_config(self):
        for config in ROOT.glob("*/config.yaml"):
            with self.subTest(config=config.parent.name):
                result = push.subprocess.run(
                    [str(config.parent / "deploy.sh"), "--dry-run"],
                    capture_output=True, text=True, check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"Config: {config}", result.stdout)
                self.assertIn("Dry run: Truss was not invoked", result.stdout)

    def test_list_does_not_run_truss(self):
        with patch.object(push.subprocess, "run") as run:
            code, output = invoke("--list")
        self.assertEqual(code, 0)
        configs = list(ROOT.glob("*/config.yaml"))
        self.assertTrue(configs)
        for config in configs:
            self.assertIn(config.parent.name, output)
        run.assert_not_called()

    def test_every_config_can_be_previewed_without_deployment(self):
        for config in ROOT.glob("*/config.yaml"):
            with self.subTest(config=config.parent.name):
                with patch.object(push.subprocess, "run") as run:
                    code, output = invoke(config.parent.name, "--dry-run")
                self.assertEqual(code, 0)
                self.assertIn(str(config), output)
                self.assertIn("Dry run: Truss was not invoked", output)
                run.assert_not_called()

    def test_push_delegates_selected_directory_and_preserves_failure(self):
        # A directory containing spaces must remain one subprocess argument.
        with tempfile.TemporaryDirectory(prefix="baseten configs ") as temp:
            root = Path(temp)
            config = root / "my-model" / "config.yaml"
            config.parent.mkdir()
            config.write_text("base_image:\n  image: example/image:tag\n")
            with patch.object(push, "DEPLOY_DIR", root):
                with patch.object(push.subprocess, "run", return_value=SimpleNamespace(returncode=23)) as run:
                    code, _ = invoke("my-model")
            self.assertEqual(code, 23)
            run.assert_called_once_with(
                ["uv", "run", "--frozen", "--directory", str(config.parent), "truss", "push"],
                cwd=root, check=False,
            )

    def test_missing_uv_has_an_actionable_error(self):
        name = next(ROOT.glob("*/config.yaml")).parent.name
        with patch.object(push.subprocess, "run", side_effect=FileNotFoundError):
            code, output = invoke(name)
        self.assertEqual(code, 1)
        self.assertIn("uv is required", output)

    def test_requires_an_explicit_bundled_config(self):
        with patch.object(push.subprocess, "run") as run:
            code, output = invoke()
            self.assertEqual(code, 2)
            self.assertIn("Choose a config", output)
            for invalid in ("../outside", "/tmp/outside", "unknown-config"):
                with self.subTest(invalid=invalid), self.assertRaises(SystemExit) as error:
                    invoke(invalid)
                self.assertEqual(error.exception.code, 2)
        run.assert_not_called()

    def test_source_registry_guard_still_rejects_missing_secret(self):
        with tempfile.TemporaryDirectory() as temp:
            config = Path(temp) / "config.yaml"
            config.write_text("base_image:\n  image: registry.distr.sh/subconscious/timrun:tag\n")
            with self.assertRaisesRegex(ValueError, "DOCKER_REGISTRY_registry.distr.sh"):
                push.validate_config(config)
            config.write_text(config.read_text() + "secrets:\n  DOCKER_REGISTRY_registry.distr.sh: null\n")
            self.assertIn("Distr registry secret", push.validate_config(config))


if __name__ == "__main__":
    unittest.main()
